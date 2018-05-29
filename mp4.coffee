Bits = require './bits'
EventEmitterModule = require './event_emitter'
Sequent = require 'sequent'
fs = require 'fs'
logger = require './logger'
h264 = require './h264'

formatDate = (date) ->
  date.toISOString()

# copyright sign + 'too' (we should not use literal '\xa9'
# since it expands to [0xc2, 0xa9])
TAG_CTOO = new Buffer([0xa9, 0x74, 0x6f, 0x6f]).toString 'utf8'

MIN_TIME_DIFF = 0.01  # seconds
READ_BUFFER_TIME = 3.0
QUEUE_BUFFER_TIME = 1.5

DEBUG = false

# If true, outgoing audio/video packets will be printed
DEBUG_OUTGOING_MP4_DATA = false

getCurrentTime = ->
  time = process.hrtime()
  return time[0] + time[1] / 1e9

class MP4File extends EventEmitterModule
  constructor: (filename) ->
    super()
    if filename?
      @open filename
    @isStopped = false

  clearBuffers: ->
    @consumedAudioChunks = 0
    @consumedVideoChunks = 0
    @bufferedAudioTime = 0
    @bufferedVideoTime = 0
    @queuedAudioTime = 0
    @queuedVideoTime = 0
    @bufferedAudioSamples = []
    @queuedAudioSampleIndex = 0
    @bufferedVideoSamples = []
    @queuedVideoSampleIndex = 0
    @isAudioEOF = false
    @isVideoEOF = false
    @sessionId++

  open: (filename) ->
    @filename = filename
    if DEBUG
      startTime = process.hrtime()
    @fileBuf = fs.readFileSync filename  # up to 1GB
    @bits = new Bits @fileBuf
    if DEBUG
      diffTime = process.hrtime startTime
      logger.debug "[mp4] took #{(diffTime[0] * 1e9 + diffTime[1]) / 1000000} ms to read #{filename}"

    @consumedAudioSamples = 0
    @consumedVideoSamples = 0
    @clearBuffers()

    @currentPlayTime = 0
    @playStartTime = null

    # sessionId will change when buffer is cleared
    @sessionId = 0

  close: ->
    logger.debug "[mp4:#{@filename}] close"
    if not @isStopped
      @stop()
    @bits = null
    @fileBuf = null
    @boxes = null
    @moovBox = null
    @mdatBox = null
    @audioTrakBox = null
    @videoTrakBox = null
    return

  parse: ->
    if DEBUG
      startTime = process.hrtime()
    @boxes = []
    while @bits.has_more_data()
      box = Box.parse @bits, null  # null == root box
      if box instanceof MovieBox
        @moovBox = box
      else if box instanceof MediaDataBox
        @mdatBox = box
      @boxes.push box
    if DEBUG
      diffTime = process.hrtime startTime
      logger.debug "[mp4] took #{(diffTime[0] * 1e9 + diffTime[1]) / 1000000} ms to parse #{@filename}"

    for child in @moovBox.children
      if child instanceof TrackBox  # trak
        tkhdBox = child.find 'tkhd'
        if tkhdBox.isAudioTrack
          @audioTrakBox = child
        else
          @videoTrakBox = child

    @numVideoSamples = @getNumVideoSamples()
    @numAudioSamples = @getNumAudioSamples()

    return

  getTree: ->
    if not @boxes?
      throw new Error "parse() must be called before dump"
    tree = { root: [] }
    for box in @boxes
      tree.root.push box.getTree()
    return tree

  dump: ->
    if not @boxes?
      throw new Error "parse() must be called before dump"
    for box in @boxes
      process.stdout.write box.dump 0, 2
    return

  hasVideo: ->
    return @videoTrakBox?

  hasAudio: ->
    return @audioTrakBox?

  getSPS: ->
    avcCBox = @videoTrakBox.find 'avcC'
    return avcCBox.sequenceParameterSets[0]

  getPPS: ->
    avcCBox = @videoTrakBox.find 'avcC'
    return avcCBox.pictureParameterSets[0]

  getAudioSpecificConfig: ->
    esdsBox = @audioTrakBox.find 'esds'
    return esdsBox.decoderConfigDescriptor.decoderSpecificInfo.specificInfo

  stop: ->
    @isStopped = true

  isPaused: ->
    return @isStopped

  pause: ->
    if not @isStopped
      @isStopped = true
      logger.debug "[mp4:#{@filename}] paused at #{@currentPlayTime} (server mp4 head time)"
    else
      logger.debug "[mp4:#{@filename}] already paused"

  sendVideoPacketsSinceLastKeyFrame: (endSeconds, callback) ->
    if not @videoTrakBox?  # video trak does not exist
      callback? null
      return

    # Get next sample number
    stblBox = @videoTrakBox.child('mdia').child('minf').child('stbl')
    sttsBox = stblBox.child('stts') # TimeToSampleBox
    videoSample = sttsBox.getSampleAfterSeconds endSeconds
    if videoSample?
      videoSampleNumber = videoSample.sampleNumber
    else
      videoSampleNumber = @numVideoSamples + 1

    samples = []
    isFirstSample = true
    loop
      rawSample = @getSample videoSampleNumber, @videoTrakBox
      isKeyFrameFound = false
      if rawSample?
        nalUnits = @parseH264Sample rawSample.data
        for nalUnit in nalUnits
          if (nalUnit[0] & 0x1f) is h264.NAL_UNIT_TYPE_IDR_PICTURE
            isKeyFrameFound = true
            break
        if not isFirstSample
          samples.unshift
            pts: rawSample.pts
            dts: rawSample.dts
            time: rawSample.time
            data: nalUnits
      if isFirstSample
        isFirstSample = false
      if isKeyFrameFound
        break
      videoSampleNumber--
      if videoSampleNumber <= 0
        break
    for sample in samples
      @emit 'video_data', sample.data, sample.pts, sample.dts

    callback? null

  resume: ->
    @play()

  isAudioEOFReached: ->
    return (@bufferedAudioSamples.length is 0) and
      (@consumedAudioSamples is @numAudioSamples)

  isVideoEOFReached: ->
    return (@bufferedVideoSamples.length is 0) and
      (@consumedVideoSamples is @numVideoSamples)

  fillBuffer: (callback) ->
    seq = new Sequent

    @bufferAudio =>
      # audio samples has been buffered
      seq.done()

    @bufferVideo =>
      # video samples has been buffered
      seq.done()

    seq.wait 2, callback

  seek: (seekSeconds=0) ->
    logger.debug "[mp4:#{@filename}] seek: seconds=#{seekSeconds}"
    @clearBuffers()

    if @videoTrakBox?
      # Seek video sample
      stblBox = @videoTrakBox.child('mdia').child('minf').child('stbl')
      sttsBox = stblBox.child('stts') # TimeToSampleBox
      videoSample = sttsBox.getSampleAfterSeconds seekSeconds
      if videoSample?
        logger.debug "video sample >= #{seekSeconds} is #{JSON.stringify videoSample}"
        videoSampleSeconds = videoSample.seconds
        @currentPlayTime = videoSampleSeconds
        videoSampleNumber = videoSample.sampleNumber
      else
        # No video sample left
        logger.debug "video sample >= #{seekSeconds} does not exist"
        @isVideoEOF = true
        @currentPlayTime = @getDurationSeconds()
        videoSampleNumber = @numVideoSamples + 1
        videoSampleSeconds = @currentPlayTime
    else
      videoSampleNumber = null
      videoSampleSeconds = null

    if @audioTrakBox?
      # Seek audio sample
      stblBox = @audioTrakBox.child('mdia').child('minf').child('stbl')
      sttsBox = stblBox.child('stts') # TimeToSampleBox
      audioSample = sttsBox.getSampleAfterSeconds seekSeconds
      if audioSample?
        logger.debug "audio sample >= #{seekSeconds} is #{JSON.stringify audioSample}"
        audioSampleNumber = audioSample.sampleNumber

        if videoSampleSeconds? and (videoSampleSeconds <= audioSample.seconds)
          minTime = videoSampleSeconds
        else
          minTime = audioSample.seconds
        if @currentPlayTime isnt minTime
          @currentPlayTime = minTime
      else
        # No audio sample left
        logger.debug "audio sample >= #{seekSeconds} does not exist"
        audioSampleNumber = @numAudioSamples + 1
        @isAudioEOF = true
    else
      audioSampleNumber = null

    if audioSampleNumber?
      @consumedAudioSamples = audioSampleNumber - 1

    if videoSampleNumber?
      @consumedVideoSamples = videoSampleNumber - 1

    logger.debug "[mp4:#{@filename}] set current play time to #{@currentPlayTime}"
    return @currentPlayTime

  play: ->
    logger.debug "[mp4:#{@filename}] start playing from #{@currentPlayTime} (server mp4 head time)"
    @fillBuffer =>
      @isStopped = false
      @playStartTime = getCurrentTime() - @currentPlayTime
      if @isAudioEOFReached()
        @isAudioEOF = true
      if @isVideoEOFReached()
        @isVideoEOF = true
      if @checkEOF()
        # EOF reached
        return false
      else
        @queueBufferedSamples()
        return true

  checkAudioBuffer: ->
    timeDiff = @bufferedAudioTime - @currentPlayTime
    if timeDiff < READ_BUFFER_TIME
      # Fill audio buffer
      if @readNextAudioChunk()
        # Audio EOF not reached
        @queueBufferedSamples()
    else
      @queueBufferedSamples()
    return

  checkVideoBuffer: ->
    timeDiff = @bufferedVideoTime - @currentPlayTime
    if timeDiff < READ_BUFFER_TIME
      # Fill video buffer
      if @readNextVideoChunk()
        # Video EOF not reached
        @queueBufferedSamples()
    else
      @queueBufferedSamples()
    return

  startStreaming: ->
    @queueBufferedSamples()

  updateCurrentPlayTime: ->
    @currentPlayTime = getCurrentTime() - @playStartTime

  queueBufferedAudioSamples: ->
    audioSample = @bufferedAudioSamples[@queuedAudioSampleIndex]
    if not audioSample?  # @bufferedAudioSamples is empty
      return
    timeDiff = audioSample.time - @currentPlayTime
    if timeDiff <= MIN_TIME_DIFF
      @bufferedAudioSamples.shift()
      @queuedAudioSampleIndex--
      if DEBUG_OUTGOING_MP4_DATA
        logger.info "emit audio_data pts=#{audioSample.pts}"
      @emit 'audio_data', audioSample.data, audioSample.pts
      @updateCurrentPlayTime()
      if (@queuedAudioSampleIndex is 0) and (@consumedAudioSamples is @numAudioSamples)
        # No audio sample left
        @isAudioEOF = true
        @checkEOF()
    else
      if not @isStopped
        sessionId = @sessionId
        setTimeout =>
          if (not @isStopped) and (@sessionId is sessionId)
            @bufferedAudioSamples.shift()
            @queuedAudioSampleIndex--
            if DEBUG_OUTGOING_MP4_DATA
              logger.info "emit timed audio_data pts=#{audioSample.pts}"
            @emit 'audio_data', audioSample.data, audioSample.pts
            @updateCurrentPlayTime()
            if (@queuedAudioSampleIndex is 0) and (@consumedAudioSamples is @numAudioSamples)
              # No audio sample left
              @isAudioEOF = true
              @checkEOF()
            else
              @checkAudioBuffer()
        , timeDiff * 1000
    @queuedAudioSampleIndex++
    @queuedAudioTime = audioSample.time
    if @queuedAudioTime - @currentPlayTime < QUEUE_BUFFER_TIME
      @queueBufferedSamples()

  queueBufferedVideoSamples: ->
    if @isStopped
      return
    videoSample = @bufferedVideoSamples[@queuedVideoSampleIndex]
    if not videoSample?  # @bufferedVideoSamples is empty
      return
    timeDiff = videoSample.time - @currentPlayTime
    if timeDiff <= MIN_TIME_DIFF
      @bufferedVideoSamples.shift()
      @queuedVideoSampleIndex--
      if DEBUG_OUTGOING_MP4_DATA
        totalBytes = 0
        for nalUnit in videoSample.data
          totalBytes += nalUnit.length
        logger.info "emit video_data pts=#{videoSample.pts} dts=#{videoSample.dts} bytes=#{totalBytes}"
      @emit 'video_data', videoSample.data, videoSample.pts, videoSample.dts
      @updateCurrentPlayTime()
      if (@queuedVideoSampleIndex is 0) and (@consumedVideoSamples is @numVideoSamples)
        # No video sample left
        @isVideoEOF = true
        @checkEOF()
    else
      sessionId = @sessionId
      setTimeout =>
        if (not @isStopped) and (@sessionId is sessionId)
          @bufferedVideoSamples.shift()
          @queuedVideoSampleIndex--
          if DEBUG_OUTGOING_MP4_DATA
            totalBytes = 0
            for nalUnit in videoSample.data
              totalBytes += nalUnit.length
            logger.info "emit timed video_data pts=#{videoSample.pts} dts=#{videoSample.dts} bytes=#{totalBytes}"
          @emit 'video_data', videoSample.data, videoSample.pts, videoSample.dts
          @updateCurrentPlayTime()
          if (@queuedVideoSampleIndex is 0) and (@consumedVideoSamples is @numVideoSamples)
            # No video sample left
            @isVideoEOF = true
            @checkEOF()
          else
            @checkVideoBuffer()
      , timeDiff * 1000
    @queuedVideoSampleIndex++
    @queuedVideoTime = videoSample.time
    if @queuedVideoTime - @currentPlayTime < QUEUE_BUFFER_TIME
      @queueBufferedSamples()

  queueBufferedSamples: ->
    if @isStopped
      return

    # Determine which of audio or video should be sent first
    firstAudioTime = @bufferedAudioSamples[@queuedAudioSampleIndex]?.time
    firstVideoTime = @bufferedVideoSamples[@queuedVideoSampleIndex]?.time
    if firstAudioTime? and firstVideoTime?
      if firstVideoTime <= firstAudioTime
        @queueBufferedVideoSamples()
        @queueBufferedAudioSamples()
      else
        @queueBufferedAudioSamples()
        @queueBufferedVideoSamples()
    else
      @queueBufferedAudioSamples()
      @queueBufferedVideoSamples()

  checkEOF: ->
    if @isAudioEOF and @isVideoEOF
      @stop()
      @emit 'eof'
      return true
    return false

  bufferAudio: (callback) ->
    # TODO: Use async
    while @bufferedAudioTime < @currentPlayTime + READ_BUFFER_TIME
      if not @readNextAudioChunk()
        # No audio sample left
        break
    callback?()

  bufferVideo: (callback) ->
    # TODO: Use async
    while @bufferedVideoTime < @currentPlayTime + READ_BUFFER_TIME
      if not @readNextVideoChunk()
        # No video sample left
        break
    callback?()

  getNumVideoSamples: ->
    if @videoTrakBox?
      sttsBox = @videoTrakBox.find 'stts'
      return sttsBox.getTotalSamples()
    else
      return 0

  getNumAudioSamples: ->
    if @audioTrakBox?
      sttsBox = @audioTrakBox.find 'stts'
      return sttsBox.getTotalSamples()
    else
      return 0

  # Returns the timestamp of the last sample in the file
  getLastTimestamp: ->
    if @videoTrakBox?
      numVideoSamples = @getNumVideoSamples()
      sttsBox = @videoTrakBox.find 'stts'
      videoLastTimestamp = sttsBox.getDecodingTime(numVideoSamples).seconds
    else
      videoLastTimestamp = 0

    if @audioTrakBox?
      numAudioSamples = @getNumAudioSamples()
      sttsBox = @audioTrakBox.find 'stts'
      audioLastTimestamp = sttsBox.getDecodingTime(numAudioSamples).seconds
    else
      audioLastTimestamp = 0

    if audioLastTimestamp > videoLastTimestamp
      return audioLastTimestamp
    else
      return videoLastTimestamp

  getDurationSeconds: ->
    mvhdBox = @moovBox.child('mvhd')
    return mvhdBox.durationSeconds

  parseH264Sample: (buf) ->
    # The format is defined in ISO 14496-15 5.2.3
    # <length><NAL unit> <length><NAL unit> ...

    avcCBox = @videoTrakBox.find 'avcC'
    lengthSize = avcCBox.lengthSizeMinusOne + 1
    bits = new Bits buf

    nalUnits = []

    while bits.has_more_data()
      length = bits.read_bits lengthSize * 8
      nalUnits.push bits.read_bytes(length)

    if bits.get_remaining_bits() isnt 0
      throw new Error "number of remaining bits is not zero: #{bits.get_remaining_bits()}"

    return nalUnits

  getSample: (sampleNumber, trakBox) ->
    stblBox = trakBox.child('mdia').child('minf').child('stbl')
    sttsBox = stblBox.child 'stts'
    stscBox = stblBox.child 'stsc'
    chunkNumber = stscBox.findChunk sampleNumber

    # Get chunk offset in the file
    stcoBox = stblBox.child 'stco'
    chunkOffset = stcoBox.getChunkOffset chunkNumber

    firstSampleNumberInChunk = stscBox.getFirstSampleNumberInChunk chunkNumber

    # Get an array of sample sizes in this chunk
    stszBox = stblBox.child 'stsz'
    sampleSizes = stszBox.getSampleSizes firstSampleNumberInChunk,
      sampleNumber - firstSampleNumberInChunk + 1

    cttsBox = stblBox.child 'ctts'
    samples = []
    sampleOffset = 0
    mdhdBox = trakBox.child('mdia').child('mdhd')
    for sampleSize, i in sampleSizes
      if firstSampleNumberInChunk + i is sampleNumber
        compositionTimeOffset = 0
        if cttsBox?
          compositionTimeOffset = cttsBox.getCompositionTimeOffset sampleNumber
        sampleTime = sttsBox.getDecodingTime sampleNumber
        compositionTime = sampleTime.time + compositionTimeOffset
        if mdhdBox.timescale isnt 90000
          pts = Math.floor(compositionTime * 90000 / mdhdBox.timescale)
          dts = Math.floor(sampleTime.time * 90000 / mdhdBox.timescale)
        else
          pts = compositionTime
          dts = sampleTime.time
        return {
          pts: pts
          dts: dts
          time: sampleTime.seconds
          data: @fileBuf[chunkOffset+sampleOffset...chunkOffset+sampleOffset+sampleSize]
        }
      sampleOffset += sampleSize

    return null

  readChunk: (chunkNumber, fromSampleNumber, trakBox) ->
    stblBox = trakBox.child('mdia').child('minf').child('stbl')
    sttsBox = stblBox.child 'stts'
    stscBox = stblBox.child 'stsc'
    numSamplesInChunk = stscBox.getNumSamplesInChunk chunkNumber

    # Get chunk offset in the file
    stcoBox = stblBox.child 'stco'
    chunkOffset = stcoBox.getChunkOffset chunkNumber

    firstSampleNumberInChunk = stscBox.getFirstSampleNumberInChunk chunkNumber

    # Get an array of sample sizes in this chunk
    stszBox = stblBox.child 'stsz'
    sampleSizes = stszBox.getSampleSizes firstSampleNumberInChunk, numSamplesInChunk

    cttsBox = stblBox.child 'ctts'
    samples = []
    sampleOffset = 0
    mdhdBox = trakBox.child('mdia').child('mdhd')
    for sampleSize, i in sampleSizes
      if firstSampleNumberInChunk + i >= fromSampleNumber
        compositionTimeOffset = 0
        if cttsBox?
          compositionTimeOffset = cttsBox.getCompositionTimeOffset firstSampleNumberInChunk + i
        sampleTime = sttsBox.getDecodingTime firstSampleNumberInChunk + i
        compositionTime = sampleTime.time + compositionTimeOffset
        if mdhdBox.timescale isnt 90000
          pts = Math.floor(compositionTime * 90000 / mdhdBox.timescale)
          dts = Math.floor(sampleTime.time * 90000 / mdhdBox.timescale)
        else
          pts = compositionTime
          dts = sampleTime.time
        samples.push {
          pts: pts
          dts: dts
          time: sampleTime.seconds
          data: @fileBuf[chunkOffset+sampleOffset...chunkOffset+sampleOffset+sampleSize]
        }
      sampleOffset += sampleSize

    return samples

  readNextVideoChunk: ->
    if @consumedVideoSamples >= @numVideoSamples
      return false

    if @consumedVideoChunks is 0 and @consumedVideoSamples isnt 0 # seeked
      stscBox = @videoTrakBox.find 'stsc'
      chunkNumber = stscBox.findChunk @consumedVideoSamples + 1
      samples = @readChunk chunkNumber, @consumedVideoSamples + 1, @videoTrakBox
      @consumedVideoChunks = chunkNumber
    else
      samples = @readChunk @consumedVideoChunks + 1, @consumedVideoSamples + 1, @videoTrakBox
      @consumedVideoChunks++

    for sample in samples
      nalUnits = @parseH264Sample sample.data
      sample.data = nalUnits

    numSamples = samples.length
    @consumedVideoSamples += numSamples
    @bufferedVideoTime = samples[numSamples - 1].time
    @bufferedVideoSamples = @bufferedVideoSamples.concat samples

    return true

  parseAACSample: (buf) ->
    # nop

  readNextAudioChunk: ->
    if @consumedAudioSamples >= @numAudioSamples
      return false

    if @consumedAudioChunks is 0 and @consumedAudioSamples isnt 0 # seeked
      stscBox = @audioTrakBox.find 'stsc'
      chunkNumber = stscBox.findChunk @consumedAudioSamples + 1
      samples = @readChunk chunkNumber, @consumedAudioSamples + 1, @audioTrakBox
      @consumedAudioChunks = chunkNumber
    else
      samples = @readChunk @consumedAudioChunks + 1, @consumedAudioSamples + 1, @audioTrakBox
      @consumedAudioChunks++

#    for sample in samples
#      @parseAACSample sample.data

    @consumedAudioSamples += samples.length
    @bufferedAudioTime = samples[samples.length-1].time
    @bufferedAudioSamples = @bufferedAudioSamples.concat samples

    return true


class Box
  # time: seconds since midnight, Jan. 1, 1904 UTC
  @mp4TimeToDate: (time) ->
    return new Date(new Date('1904-01-01 00:00:00+0000').getTime() + time * 1000)

  getTree: ->
    obj =
      type: @typeStr
    if @children?
      obj.children = []
      for child in @children
        obj.children.push child.getTree()
    return obj

  dump: (depth=0, detailLevel=0) ->
    str = ''
    for i in [0...depth]
      str += '  '
    str += "#{@typeStr}"
    if detailLevel > 0
      detailString = @getDetails detailLevel
      if detailString?
        str += " (#{detailString})"
    str += "\n"
    if @children?
      for child in @children
        str += child.dump depth+1, detailLevel
    return str

  getDetails: (detailLevel) ->
    return null

  constructor: (info) ->
    for name, value of info
      @[name] = value
    if @data?
      @read @data

  readFullBoxHeader: (bits) ->
    @version = bits.read_byte()
    @flags = bits.read_bits 24
    return

  findParent: (typeStr) ->
    if @parent?
      if @parent.typeStr is typeStr
        return @parent
      else
        return @parent.findParent typeStr
    else
      return null

  child: (typeStr) ->
    if @typeStr is typeStr
      return this
    else
      if @children?
        for child in @children
          if child.typeStr is typeStr
            return child
      return null

  find: (typeStr) ->
    if @typeStr is typeStr
      return this
    else
      if @children?
        for child in @children
          box = child.find typeStr
          if box?
            return box
      return null

  read: (buf) ->

  @readHeader: (bits, destObj) ->
    destObj.size = bits.read_uint32()
    destObj.type = bits.read_bytes 4
    destObj.typeStr = destObj.type.toString 'utf8'
    headerLen = 8
    if destObj.size is 1
      destObj.size = bits.read_bits 64  # TODO: might lose some precision
      headerLen += 8
    if destObj.typeStr is 'uuid'
      destObj.usertype = bits.read_bytes 16
      headerLen += 16

    if destObj.size > 0
      destObj.data = bits.read_bytes(destObj.size - headerLen)
    else
      destObj.data = bits.remaining_buffer()
      destObj.size = headerLen + destObj.data.length

    return

  @readLanguageCode: (bits) ->
    return Box.readASCII(bits) + Box.readASCII(bits) + Box.readASCII(bits)

  @readASCII: (bits) ->
    diff = bits.read_bits 5
    return String.fromCharCode 0x60 + diff

  @parse: (bits, parent=null, cls) ->
    info = {}
    info.parent = parent
    @readHeader bits, info

    switch info.typeStr
      when 'ftyp'
        return new FileTypeBox info
      when 'moov'
        return new MovieBox info
      when 'mvhd'
        return new MovieHeaderBox info
      when 'mdat'
        return new MediaDataBox info
      when 'trak'
        return new TrackBox info
      when 'tkhd'
        return new TrackHeaderBox info
      when 'edts'
        return new EditBox info
      when 'elst'
        return new EditListBox info
      when 'mdia'
        return new MediaBox info
      when 'iods'
        return new ObjectDescriptorBox info
      when 'mdhd'
        return new MediaHeaderBox info
      when 'hdlr'
        return new HandlerBox info
      when 'minf'
        return new MediaInformationBox info
      when 'vmhd'
        return new VideoMediaHeaderBox info
      when 'dinf'
        return new DataInformationBox info
      when 'dref'
        return new DataReferenceBox info
      when 'url '
        return new DataEntryUrlBox info
      when 'urn '
        return new DataEntryUrnBox info
      when 'stbl'
        return new SampleTableBox info
      when 'stsd'
        return new SampleDescriptionBox info
      when 'stts'
        return new TimeToSampleBox info
      when 'stss'
        return new SyncSampleBox info
      when 'stsc'
        return new SampleToChunkBox info
      when 'stsz'
        return new SampleSizeBox info
      when 'stco'
        return new ChunkOffsetBox info
      when 'smhd'
        return new SoundMediaHeaderBox info
      when 'meta'
        return new MetaBox info
      when 'pitm'
        return new PrimaryItemBox info
      when 'iloc'
        return new ItemLocationBox info
      when 'ipro'
        return new ItemProtectionBox info
      when 'infe'
        return new ItemInfoEntry info
      when 'iinf'
        return new ItemInfoBox info
      when 'ilst'
        return new MetadataItemListBox info
      when 'gsst'
        return new GoogleGSSTBox info
      when 'gstd'
        return new GoogleGSTDBox info
      when 'gssd'
        return new GoogleGSSDBox info
      when 'gspu'
        return new GoogleGSPUBox info
      when 'gspm'
        return new GoogleGSPMBox info
      when 'gshh'
        return new GoogleGSHHBox info
      when 'udta'
        return new UserDataBox info
      when 'avc1'
        return new AVCSampleEntry info
      when 'avcC'
        return new AVCConfigurationBox info
      when 'btrt'
        return new MPEG4BitRateBox info
      when 'm4ds'
        return new MPEG4ExtensionDescriptorsBox info
      when 'mp4a'
        return new MP4AudioSampleEntry info
      when 'esds'
        return new ESDBox info
      when 'free'
        return new FreeSpaceBox info
      when 'ctts'
        return new CompositionOffsetBox info
      when TAG_CTOO
        return new CTOOBox info
      else
        if cls?
          return new cls info
        else
          logger.warn "[mp4] warning: skipping unknown (not implemented) box type: #{info.typeStr} (0x#{info.type.toString('hex')})"
          return new Box info

class Container extends Box
  read: (buf) ->
    bits = new Bits buf
    @children = []
    while bits.has_more_data()
      box = Box.parse bits, this
      @children.push box
    return

#  getDetails: (detailLevel) ->
#    "Container"

# moov
class MovieBox extends Container

# stbl
class SampleTableBox extends Container

# dinf
class DataInformationBox extends Container

# udta
class UserDataBox extends Container

# minf
class MediaInformationBox extends Container

# mdia
class MediaBox extends Container

# edts
class EditBox extends Container

# trak
class TrackBox extends Container

# ftyp
class FileTypeBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @majorBrand = bits.read_uint32()
    @majorBrandStr = Bits.uintToString @majorBrand, 4
    @minorVersion = bits.read_uint32()
    @compatibleBrands = []
    while bits.has_more_data()
      brand = bits.read_bytes 4
      brandStr = brand.toString 'utf8'
      @compatibleBrands.push
        brand: brand
        brandStr: brandStr
    return

  getDetails: (detailLevel) ->
    "brand=#{@majorBrandStr} version=#{@minorVersion}"

  getTree: ->
    obj = new Box
    obj.brand = @majorBrandStr
    obj.version = @minorVersion
    return obj

# mvhd
class MovieHeaderBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    if @version is 1
      @creationTime = bits.read_bits 64  # TODO: loses precision
      @creationDate = Box.mp4TimeToDate @creationTime
      @modificationTime = bits.read_bits 64  # TODO: loses precision
      @modificationDate = Box.mp4TimeToDate @modificationTime
      @timescale = bits.read_uint32()
      @duration = bits.read_bits 64  # TODO: loses precision
      @durationSeconds = @duration / @timescale
    else  # @version is 0
      @creationTime = bits.read_bits 32  # TODO: loses precision
      @creationDate = Box.mp4TimeToDate @creationTime
      @modificationTime = bits.read_bits 32  # TODO: loses precision
      @modificationDate = Box.mp4TimeToDate @modificationTime
      @timescale = bits.read_uint32()
      @duration = bits.read_bits 32  # TODO: loses precision
      @durationSeconds = @duration / @timescale
    @rate = bits.read_int 32
    if @rate isnt 0x00010000  # 1.0
      logger.warn "[mp4] warning: Irregular rate found in mvhd box: #{@rate}"
    @volume = bits.read_int 16
    if @volume isnt 0x0100  # full volume
      logger.warn "[mp4] warning: Irregular volume found in mvhd box: #{@volume}"
    reserved = bits.read_bits 16
    if reserved isnt 0
      throw new Error "reserved bits are not all zero: #{reserved}"
    reservedInt1 = bits.read_int 32
    if reservedInt1 isnt 0
      throw new Error "reserved int(32) (1) is not zero: #{reservedInt1}"
    reservedInt2 = bits.read_int 32
    if reservedInt2 isnt 0
      throw new Error "reserved int(32) (2) is not zero: #{reservedInt2}"
    bits.skip_bytes 4 * 9  # Unity matrix
    bits.skip_bytes 4 * 6  # pre_defined
    @nextTrackID = bits.read_uint32()

    if bits.has_more_data()
      throw new Error "mvhd box has more data"

  getDetails: (detailLevel) ->
    "created=#{formatDate @creationDate} modified=#{formatDate @modificationDate} timescale=#{@timescale} durationSeconds=#{@durationSeconds}"

  getTree: ->
    obj = new Box
    obj.creationDate = @creationDate
    obj.modificationDate = @modificationDate
    obj.timescale = @timescale
    obj.duration = @duration
    obj.durationSeconds = @durationSeconds
    return obj

# Object Descriptor Box: contains an Object Descriptor or an Initial Object Descriptor
# (iods)
# Defined in ISO 14496-14
class ObjectDescriptorBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits
    return

# Track header box: specifies the characteristics of a single track (tkhd)
class TrackHeaderBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    if @version is 1
      @creationTime = bits.read_bits 64  # TODO: loses precision
      @creationDate = Box.mp4TimeToDate @creationTime
      @modificationTime = bits.read_bits 64  # TODO: loses precision
      @modificationDate = Box.mp4TimeToDate @modificationTime
      @trackID = bits.read_uint32()
      reserved = bits.read_uint32()
      if reserved isnt 0
        throw new Error "tkhd: reserved bits are not zero: #{reserved}"
      @duration = bits.read_bits 64  # TODO: loses precision
    else  # @version is 0
      @creationTime = bits.read_bits 32  # TODO: loses precision
      @creationDate = Box.mp4TimeToDate @creationTime
      @modificationTime = bits.read_bits 32  # TODO: loses precision
      @modificationDate = Box.mp4TimeToDate @modificationTime
      @trackID = bits.read_uint32()
      reserved = bits.read_uint32()
      if reserved isnt 0
        throw new Error "tkhd: reserved bits are not zero: #{reserved}"
      @duration = bits.read_bits 32  # TODO: loses precision
    reserved = bits.read_bits 64
    if reserved isnt 0
      throw new Error "tkhd: reserved bits are not zero: #{reserved}"
    @layer = bits.read_int 16
    if @layer isnt 0
      logger.warn "[mp4] warning: layer is not 0 in tkhd box: #{@layer}"
    @alternateGroup = bits.read_int 16
#    if @alternateGroup isnt 0
#      logger.warn "[mp4] warning: alternate_group is not 0 in tkhd box: #{@alternateGroup}"
    @volume = bits.read_int 16
    if @volume is 0x0100
      @isAudioTrack = true
    else
      @isAudioTrack = false
    reserved = bits.read_bits 16
    if reserved isnt 0
      throw new Error "tkhd: reserved bits are not zero: #{reserved}"
    bits.skip_bytes 4 * 9
    @width = bits.read_uint32() / 65536  # fixed-point 16.16 value
    @height = bits.read_uint32() / 65536  # fixed-point 16.16 value

    if bits.has_more_data()
      throw new Error "tkhd box has more data"

  getDetails: (detailLevel) ->
    str = "created=#{formatDate @creationDate} modified=#{formatDate @modificationDate}"
    if @isAudioTrack
      str += " audio"
    else
      str += " video; width=#{@width} height=#{@height}"
    return str

  getTree: ->
    obj = new Box
    obj.creationDate = @creationDate
    obj.modificationDate = @modificationDate
    obj.isAudioTrack = @isAudioTrack
    obj.width = @width
    obj.height = @height
    return obj

# elst
# Edit list box: explicit timeline map
class EditListBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    # moov
    #   mvhd <- find target
    #   iods
    #   trak
    #     tkhd
    #     edts
    #       elst <- self
    mvhdBox = @findParent('moov').find('mvhd')

    # We cannot get mdhd box at this time, since it is not parsed yet

    entryCount = bits.read_uint32()
    @entries = []
    for i in [1..entryCount]
      if @version is 1
        segmentDuration = bits.read_bits 64  # TODO: loses precision
        mediaTime = bits.read_int 64
      else  # @version is 0
        segmentDuration = bits.read_bits 32
        mediaTime = bits.read_int 32
      mediaRateInteger = bits.read_int 16
      mediaRateFraction = bits.read_int 16
      if mediaRateFraction isnt 0
        logger.warn "[mp4] warning: media_rate_fraction is not 0 in elst box: #{mediaRateFraction}"
      @entries.push
        segmentDuration: segmentDuration  # in Movie Header Box (mvhd) timescale
        segmentDurationSeconds: segmentDuration / mvhdBox.timescale
        mediaTime: mediaTime  # in media (mdhd) timescale
        mediaRate: mediaRateInteger + mediaRateFraction / 65536 # TODO: Is this correct?

    if bits.has_more_data()
      throw new Error "elst box has more data"

  # Returns the starting offset for this track in mdhd timescale units
  getEmptyDuration: ->
    time = 0
    for entry in @entries
      if entry.mediaTime is -1  # empty edit
        # moov
        #   mvhd <- find target
        #   iods
        #   trak
        #     tkhd
        #     edts
        #       elst <- self
        mvhdBox = @findParent('moov').child('mvhd')

        #   trak
        #     tkhd
        #     edts
        #       elst <- self
        #     mdia
        #       mdhd <- find target
        mdhdBox = @findParent('trak').child('mdia').child('mdhd')
        if not mdhdBox?
          throw new Error "cannot access mdhd box (not parsed yet?)"

        # Convert segmentDuration from mvhd timescale to mdhd timescale
        time += entry.segmentDuration * mdhdBox.timescale / mvhdBox.timescale
      else
        # mediaTime is already in mdhd timescale, so no conversion needed
        return time + entry.mediaTime

  getDetails: (detailLevel) ->
    @entries.map((entry, index) ->
      "[#{index}]:segmentDuration=#{entry.segmentDuration},segmentDurationSeconds=#{entry.segmentDurationSeconds},mediaTime=#{entry.mediaTime},mediaRate=#{entry.mediaRate}"
    ).join(',')

  getTree: ->
    obj = new Box
    obj.entries = @entries
    return obj

# Media Header Box (mdhd): declares overall information
# Container: Media Box ('mdia')
# Defined in ISO 14496-12
class MediaHeaderBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    if @version is 1
      @creationTime = bits.read_bits 64  # TODO: loses precision
      @creationDate = Box.mp4TimeToDate @creationTime
      @modificationTime = bits.read_bits 64  # TODO: loses precision
      @modificationDate = Box.mp4TimeToDate @modificationTime
      @timescale = bits.read_uint32()
      @duration = bits.read_bits 64  # TODO: loses precision
    else  # @version is 0
      @creationTime = bits.read_bits 32
      @creationDate = Box.mp4TimeToDate @creationTime
      @modificationTime = bits.read_bits 32
      @modificationDate = Box.mp4TimeToDate @modificationTime
      @timescale = bits.read_uint32()
      @duration = bits.read_uint32()
    @durationSeconds = @duration / @timescale
    pad = bits.read_bit()
    if pad isnt 0
      throw new Error "mdhd: pad is not 0: #{pad}"
    @language = Box.readLanguageCode bits
    pre_defined = bits.read_bits 16
    if pre_defined isnt 0
      throw new Error "mdhd: pre_defined is not 0: #{pre_defined}"

  getDetails: (detailLevel) ->
    "created=#{formatDate @creationDate} modified=#{formatDate @modificationDate} timescale=#{@timescale} durationSeconds=#{@durationSeconds} lang=#{@language}"

  getTree: ->
    obj = new Box
    obj.creationDate = @creationDate
    obj.modificationDate = @modificationDate
    obj.timescale = @timescale
    obj.duration = @duration
    obj.durationSeconds = @durationSeconds
    obj.language = @language
    return obj

# Handler Reference Box (hdlr): declares the nature of the media in a track
# Container: Media Box ('mdia') or Meta Box ('meta')
# Defined in ISO 14496-12
class HandlerBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    pre_defined = bits.read_bits 32
    if pre_defined isnt 0
      throw new Error "hdlr: pre_defined is not 0 (got #{pre_defined})"
    @handlerType = bits.read_bytes(4).toString 'utf8'
    # vide: Video track
    # soun: Audio track
    # hint: Hint track
    bits.skip_bytes 4 * 3  # reserved 0 bits (may not be all zero if handlerType is
                           # none of the above)
    @name = bits.get_string()
    return

  getDetails: (detailLevel) ->
    "handlerType=#{@handlerType} name=#{@name}"

  getTree: ->
    obj = new Box
    obj.handlerType = @handlerType
    obj.name = @name
    return obj

# Video Media Header Box (vmhd): general presentation information
class VideoMediaHeaderBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @graphicsmode = bits.read_bits 16
    if @graphicsmode isnt 0
      logger.warn "[mp4] warning: vmhd: non-standard graphicsmode: #{@graphicsmode}"
    @opcolor = {}
    @opcolor.red = bits.read_bits 16
    @opcolor.green = bits.read_bits 16
    @opcolor.blue = bits.read_bits 16

#  getDetails: (detailLevel) ->
#    "graphicsMode=#{@graphicsmode} opColor=0x#{Bits.zeropad 2, @opcolor.red.toString 16}#{Bits.zeropad 2, @opcolor.green.toString 16}#{Bits.zeropad 2, @opcolor.blue.toString 16}"

# Data Reference Box (dref): table of data references that declare
#                            locations of the media data
class DataReferenceBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    entry_count = bits.read_uint32()
    @children = []
    for i in [1..entry_count]
      @children.push Box.parse bits, this
    return

# "url "
class DataEntryUrlBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    if bits.has_more_data()
      @location = bits.get_string()
    else
      @location = null
    return

  getDetails: (detailLevel) ->
    if @location?
      "location=#{@location}"
    else
      "empty location value"

  getTree: ->
    obj = new Box
    obj.location = @location
    return obj

# "urn "
class DataEntryUrnBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    if bits.has_more_data()
      @name = bits.get_string()
    else
      @name = null
    if bits.has_more_data()
      @location = bits.get_string()
    else
      @location = null
    return

# Sample Description Box (stsd): coding type and any initialization information
# Defined in ISO 14496-12
class SampleDescriptionBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    # moov
    #   mvhd
    #   iods
    #   trak
    #     tkhd
    #     edts
    #       elst
    #     mdia
    #       mdhd
    #       hdlr <- find target
    #       minf
    #         vmhd
    #         dinf
    #           dref
    #             url
    #         stbl
    #           stsd <- self
    #             stts
    handlerRefBox = @findParent('mdia').find('hdlr')
    handlerType = handlerRefBox.handlerType

    entry_count = bits.read_uint32()
    @children = []
    for i in [1..entry_count]
      switch handlerType
        when 'soun'  # for audio tracks
          @children.push Box.parse bits, this, AudioSampleEntry
        when 'vide'  # for video tracks
          @children.push Box.parse bits, this, VisualSampleEntry
        when 'hint'  # hint track
          @children.push Box.parse bits, this, HintSampleEntry
        else
          logger.warn "[mp4] warning: ignoring a sample entry for unknown handlerType in stsd box: #{handlerType}"
    return

class HintSampleEntry extends Box
  read: (buf) ->
    bits = new Bits buf
    # SampleEntry
    reserved = bits.read_bits 8 * 6
    if reserved isnt 0
      throw new Error "VisualSampleEntry: reserved bits are not 0: #{reserved}"
    @dataReferenceIndex = bits.read_bits 16

    # unsigned int(8) data []

    return

class AudioSampleEntry extends Box
  read: (buf) ->
    bits = new Bits buf
    # SampleEntry
    reserved = bits.read_bits 8 * 6
    if reserved isnt 0
      throw new Error "AudioSampleEntry: reserved bits are not 0: #{reserved}"
    @dataReferenceIndex = bits.read_bits 16

    reserved = bits.read_bytes_sum 4 * 2
    if reserved isnt 0
      throw new Error "AudioSampleEntry: reserved-1 bits are not 0: #{reserved}"

    @channelCount = bits.read_bits 16
    if @channelCount isnt 2
      throw new Error "AudioSampleEntry: channelCount is not 2: #{@channelCount}"

    @sampleSize = bits.read_bits 16
    if @sampleSize isnt 16
      throw new Error "AudioSampleEntry: sampleSize is not 16: #{@sampleSize}"

    pre_defined = bits.read_bits 16
    if pre_defined isnt 0
      throw new Error "AudioSampleEntry: pre_defined is not 0: #{pre_defined}"

    reserved = bits.read_bits 16
    if reserved isnt 0
      throw new Error "AudioSampleEntry: reserved-2 bits are not 0: #{reserved}"

    # moov
    #   mvhd
    #   iods
    #   trak
    #     tkhd
    #     edts
    #       elst
    #     mdia
    #       mdhd <- find target
    #       hdlr
    #       minf
    #         vmhd
    #         dinf
    #           dref
    #             url
    #         stbl
    #           stsd <- self
    #             stts
    mdhdBox = @findParent('mdia').find('mdhd')

    @sampleRate = bits.read_uint32()
    if @sampleRate isnt mdhdBox.timescale * Math.pow(2, 16)  # "<< 16" may lead to int32 overflow
      throw new Error "AudioSampleEntry: illegal sampleRate: #{@sampleRate} (should be #{mdhdBox.timescale << 16})"

    @remaining_buf = bits.remaining_buffer()
    return

class VisualSampleEntry extends Box
  read: (buf) ->
    bits = new Bits buf
    # SampleEntry
    reserved = bits.read_bits 8 * 6
    if reserved isnt 0
      throw new Error "VisualSampleEntry: reserved bits are not 0: #{reserved}"
    @dataReferenceIndex = bits.read_bits 16

    # VisualSampleEntry
    pre_defined = bits.read_bits 16
    if pre_defined isnt 0
      throw new Error "VisualSampleEntry: pre_defined bits are not 0: #{pre_defined}"
    reserved = bits.read_bits 16
    if reserved isnt 0
      throw new Error "VisualSampleEntry: reserved bits are not 0: #{reserved}"
    pre_defined = bits.read_bytes_sum 4 * 3
    if pre_defined isnt 0
      throw new Error "VisualSampleEntry: pre_defined is not 0: #{pre_defined}"
    @width = bits.read_bits 16
    @height = bits.read_bits 16
    @horizontalResolution = bits.read_uint32()
    if @horizontalResolution isnt 0x00480000  # 72 dpi
      throw new Error "VisualSampleEntry: horizontalResolution is not 0x00480000: #{@horizontalResolution}"
    @verticalResolution = bits.read_uint32()
    if @verticalResolution isnt 0x00480000  # 72 dpi
      throw new Error "VisualSampleEntry: verticalResolution is not 0x00480000: #{@verticalResolution}"
    reserved = bits.read_uint32()
    if reserved isnt 0
      throw new Error "VisualSampleEntry: reserved bits are not 0: #{reserved}"
    @frameCount = bits.read_bits 16
    if @frameCount isnt 1
      throw new Error "VisualSampleEntry: frameCount is not 1: #{@frameCount}"

    # compressor name: 32 bytes
    compressorNameBytes = bits.read_byte()
    if compressorNameBytes > 0
      @compressorName = bits.read_bytes(compressorNameBytes).toString 'utf8'
    else
      @compressorName = null
    paddingLen = 32 - 1 - compressorNameBytes
    if paddingLen > 0
      bits.skip_bytes paddingLen

    @depth = bits.read_bits 16
    if @depth isnt 0x0018
      throw new Error "VisualSampleEntry: depth is not 0x0018: #{@depth}"
    pre_defined = bits.read_int 16
    if pre_defined isnt -1
      throw new Error "VisualSampleEntry: pre_defined is not -1: #{pre_defined}"

    @remaining_buf = bits.remaining_buffer()
    return

# stts
# Defined in ISO 14496-12
class TimeToSampleBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @entryCount = bits.read_uint32()
    @entries = []
    for i in [0...@entryCount]
      # number of consecutive samples that have the given duration
      sampleCount = bits.read_uint32()
      # delta of these samples in the time-scale of the media
      sampleDelta = bits.read_uint32()
      if sampleDelta < 0
        throw new Error "stts: negative sampleDelta is not allowed: #{sampleDelta}"
      @entries.push
        sampleCount: sampleCount
        sampleDelta: sampleDelta
    return

  getTotalSamples: ->
    samples = 0
    for entry in @entries
      samples += entry.sampleCount
    return samples

  # Returns the total length of this media in seconds
  getTotalLength: ->
    # mdia
    #   mdhd <- find target
    #   hdlr
    #   minf
    #     vmhd
    #     dinf
    #       dref
    #         url
    #     stbl
    #       stsd
    #         avc1
    #           avcC
    #           btrt
    #       stts <- self
    mdhdBox = @findParent('mdia').find('mdhd')

    time = 0
    for entry in @entries
      time += entry.sampleDelta * entry.sampleCount
    return time / mdhdBox.timescale

  # Returns a sample which comes exactly at or immediately after
  # the specified time (in seconds). If isExclusive=true, it excludes
  # a sample whose timestamp is equal to the specified time.
  # If there is no matching sample, this method returns null.
  getSampleAfterSeconds: (sec, isExclusive=false) ->
    timescale = @findParent('mdia').find('mdhd').timescale
    remainingTime = sec * timescale
    sampleNumber = 1
    elstBox = @findParent('trak').child('edts')?.child('elst')
    if elstBox?
      totalTime = elstBox.getEmptyDuration()
      remainingTime -= totalTime
    else
      totalTime = 0
    for entry in @entries
      numSamples = Math.ceil(remainingTime / entry.sampleDelta)
      if numSamples < 0
        numSamples = 0
      if numSamples <= entry.sampleCount
        totalTime += numSamples * entry.sampleDelta
        totalSeconds = totalTime / timescale
        if isExclusive and (totalSeconds <= sec)
          numSamples++
          totalTime += entry.sampleDelta
          totalSeconds = totalTime / timescale
        return {
          sampleNumber: sampleNumber + numSamples
          time: totalTime
          seconds: totalSeconds
        }
      sampleNumber += entry.sampleCount
      entryDuration = entry.sampleDelta * entry.sampleCount
      totalTime += entryDuration
      remainingTime -= entryDuration

    # EOF
    return null

  # Returns a sample which represents the data at the specified time
  # (in seconds). If there is no sample at the specified time, this
  # method returns null.
  getSampleAtSeconds: (sec) ->
    timescale = @findParent('mdia').find('mdhd').timescale
    remainingTime = sec * timescale
    sampleNumber = 1
    elstBox = @findParent('trak').child('edts')?.child('elst')
    if elstBox?
      totalTime = elstBox.getEmptyDuration()
      remainingTime -= totalTime
    else
      totalTime = 0
    for entry in @entries
      sampleIndexInChunk = Math.floor(remainingTime / entry.sampleDelta)
      if sampleIndexInChunk < 0
        sampleIndexInChunk = 0
      if sampleIndexInChunk < entry.sampleCount
        totalTime += sampleIndexInChunk * entry.sampleDelta
        return {
          sampleNumber: sampleNumber + sampleIndexInChunk
          time: totalTime
          seconds: totalTime / timescale
        }
      sampleNumber += entry.sampleCount
      entryDuration = entry.sampleDelta * entry.sampleCount
      totalTime += entryDuration
      remainingTime -= entryDuration

    # EOF
    return null

  # Returns a decoding time for the given sample number.
  # The sample number starts at 1.
  getDecodingTime: (sampleNumber) ->
    trakBox = @findParent('trak')
    elstBox = trakBox.child('edts')?.child('elst')
    mdhdBox = trakBox.child('mdia').child('mdhd')

    sampleNumber--
    if elstBox?
      time = elstBox.getEmptyDuration()
    else
      time = 0
    for entry in @entries
      if sampleNumber > entry.sampleCount
        time += entry.sampleDelta * entry.sampleCount
        sampleNumber -= entry.sampleCount
      else
        time += entry.sampleDelta * sampleNumber
        break
    return {
      time: time
      seconds: time / mdhdBox.timescale
    }

  getDetails: (detailLevel) ->
    str = "entryCount=#{@entryCount}"
    if detailLevel >= 2
      str += ' ' + @entries.map((entry, index) ->
        "[#{index}]:sampleCount=#{entry.sampleCount},sampleDelta=#{entry.sampleDelta}"
      ).join(',')
    return str

  getTree: ->
    obj = new Box
    obj.entries = @entries
    return obj

# stss: random access points
# If stss is not present, every sample is a random access point.
class SyncSampleBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @entryCount = bits.read_uint32()
    @sampleNumbers = []
    lastSampleNumber = -1
    for i in [0...@entryCount]
      sampleNumber = bits.read_uint32()
      if sampleNumber < lastSampleNumber
        throw new Error "stss: sample number must be in increasing order: #{sampleNumber} < #{lastSampleNumber}"
      lastSampleNumber = sampleNumber
      @sampleNumbers.push sampleNumber
    return

  getDetails: (detailLevel) ->
    if detailLevel >= 2
      "sampleNumbers=#{@sampleNumbers.join ','}"
    else
      "entryCount=#{@entryCount}"

  getTree: ->
    obj = new Box
    obj.sampleNumbers = @sampleNumbers
    return obj

# stsc: number of samples for each chunk
class SampleToChunkBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @entryCount = bits.read_uint32()
    @entries = []
    sampleNumber = 1
    for i in [0...@entryCount]
      firstChunk = bits.read_uint32()
      samplesPerChunk = bits.read_uint32()
      sampleDescriptionIndex = bits.read_uint32()
      if i > 0
        lastEntry = @entries[@entries.length - 1]
        sampleNumber += (firstChunk - lastEntry.firstChunk) * lastEntry.samplesPerChunk
      @entries.push
        firstChunk: firstChunk
        firstSample: sampleNumber
        samplesPerChunk: samplesPerChunk
        sampleDescriptionIndex: sampleDescriptionIndex

    # Determine the number of chunks of each entry
    endIndex = @entries.length - 1
    for i in [0...endIndex]
      if i is endIndex
        break
      @entries[i].numChunks = @entries[i+1].firstChunk - @entries[i].firstChunk

    # XXX: We could determine the number of chunks in the last batch because
    #      the total number of samples is known by stts box. However we don't
    #      need it.

    return

  getNumSamplesExceptLastChunk: ->
    samples = 0
    for entry in @entries
      if entry.numChunks?
        samples += entry.samplesPerChunk * entry.numChunks
    return samples

  getNumSamplesInChunk: (chunk) ->
    for entry in @entries
      if not entry.numChunks?
        # TOOD: too heavy
        sttsBox = @findParent('stbl').find 'stts'
        return entry.samplesPerChunk
      if chunk < entry.firstChunk + entry.numChunks
        return entry.samplesPerChunk
    throw new Error "Chunk not found: #{chunk}"

  findChunk: (sampleNumber) ->
    for entry in @entries
      if not entry.numChunks?
        return entry.firstChunk + Math.floor((sampleNumber-1) / entry.samplesPerChunk)
      if sampleNumber <= entry.samplesPerChunk * entry.numChunks
        return entry.firstChunk + Math.floor((sampleNumber-1) / entry.samplesPerChunk)
      sampleNumber -= entry.samplesPerChunk * entry.numChunks
    throw new Error "Chunk for sample number #{sampleNumber} is not found"

  getFirstSampleNumberInChunk: (chunkNumber) ->
    for i in [@entries.length-1..0]
      if chunkNumber >= @entries[i].firstChunk
        return @entries[i].firstSample +
          (chunkNumber - @entries[i].firstChunk) * @entries[i].samplesPerChunk
    return null

  getDetails: (detailLevel) ->
    if detailLevel >= 2
      @entries.map((entry) ->
        "firstChunk=#{entry.firstChunk} samplesPerChunk=#{entry.samplesPerChunk} sampleDescriptionIndex=#{entry.sampleDescriptionIndex}"
      ).join(', ')
    else
      "entryCount=#{@entryCount}"

  getTree: ->
    obj = new Box
    obj.entries = @entries
    return obj

# stsz: sample sizes
class SampleSizeBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    # Default sample size
    # 0: samples have different sizes
    @sampleSize = bits.read_uint32()

    # Number of samples in the track
    @sampleCount = bits.read_uint32()
    if @sampleSize is 0
      @entrySizes = []
      for i in [1..@sampleCount]
        @entrySizes.push bits.read_uint32()
    return

  # Returns an array of sample sizes beginning at sampleNumber through
  # the specified number of samples (len)
  getSampleSizes: (sampleNumber, len=1) ->
    sizes = []
    if @sampleSize isnt 0
      for i in [len...0]
        sizes.push @sampleSize
    else
      for i in [len...0]
        sizes.push @entrySizes[sampleNumber - 1]
        sampleNumber++
    return sizes

  # Returns the total bytes from sampleNumber through
  # the specified number of samples (len)
  getTotalSampleSize: (sampleNumber, len=1) ->
    if @sampleSize isnt 0  # all samples are the same size
      return @sampleSize * len
    else  # the samples have different sizes
      totalLength = 0
      for i in [len...0]
        if sampleNumber > @entrySizes.length
          throw new Error "Sample number is out of range: #{sampleNumber} > #{@entrySizes.length}"
        totalLength += @entrySizes[sampleNumber - 1]  # TODO: Is -1 correct?
        sampleNumber++
      return totalLength

  getDetails: (detailLevel) ->
    str = "sampleSize=#{@sampleSize} sampleCount=#{@sampleCount}"
    if @entrySizes?
      if detailLevel >= 2
        str += " entrySizes=#{@entrySizes.join ','}"
      else
        str += " num_entrySizes=#{@entrySizes.length}"
    return str

  getTree: ->
    obj = new Box
    obj.sampleSize = @sampleSize
    obj.sampleCount = @sampleCount
    if @entrySizes?
      obj.entrySizes = @entrySizes
    return obj

# stco: chunk offsets relative to the beginning of the file
class ChunkOffsetBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @entryCount = bits.read_uint32()
    @chunkOffsets = []
    for i in [1..@entryCount]
      @chunkOffsets.push bits.read_uint32()
    return

  # Returns a position of the chunk relative to the beginning of the file
  getChunkOffset: (chunkNumber) ->
    if (chunkNumber <= 0) or (chunkNumber > @chunkOffsets.length)
      throw new Error "Chunk number out of range: #{chunkNumber} (len=#{@chunkOffsets.length})"
    return @chunkOffsets[chunkNumber - 1]

  getDetails: (detailLevel) ->
    if detailLevel >= 2
      "chunkOffsets=#{@chunkOffsets.join ','}"
    else
      "entryCount=#{@entryCount}"

  getTree: ->
    obj = new Box
    obj.chunkOffsets = @chunkOffsets
    return obj

# smhd
class SoundMediaHeaderBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @balance = bits.read_bits 16
    if @balance isnt 0
      throw new Error "smhd: balance is not 0: #{@balance}"

    reserved = bits.read_bits 16
    if reserved isnt 0
      throw new Error "smhd: reserved bits are not 0: #{reserved}"

    return

# meta: descriptive or annotative metadata
class MetaBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @children = []
    while bits.has_more_data()
      box = Box.parse bits, this
      @children.push box
    return

# pitm: one of the referenced items
class PrimaryItemBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @itemID = bits.read_bits 16
    return

# iloc
class ItemLocationBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @offsetSize = bits.read_bits 4
    @lengthSize = bits.read_bits 4
    @baseOffsetSize = bits.read_bits 4
    @reserved = bits.read_bits 4
    @itemCount = bits.read_bits 16
    @items = []
    for i in [0...@itemCount]
      itemID = bits.read_bits 16
      dataReferenceIndex = bits.read_bits 16
      baseOffset = bits.read_bits @baseOffsetSize * 8
      extentCount = bits.read_bits 16
      extents = []
      for j in [0...extentCount]
        extentOffset = bits.read_bits @offsetSize * 8
        extentLength = bits.read_bits @lengthSize * 8
        extents.push
          extentOffset: extentOffset
          extentLength: extentLength
      @items.push
        itemID: itemID
        dataReferenceIndex: dataReferenceIndex
        baseOffset: baseOffset
        extentCount: extentCount
        extents: extents
    return

# ipro: an array of item protection information
class ItemProtectionBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @protectionCount = bits.read_bits 16

    @children = []
    for i in [1..@protectionCount]
      box = Box.parse bits, this
      @children.push box
    return

# infe: extra information about selected items
class ItemInfoEntry extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @itemID = bits.read_bits 16
    @itemProtectionIndex = bits.read_bits 16
    @itemName = bits.get_string()
    @contentType = bits.get_string()
    if bits.has_more_data()
      @contentEncoding = bits.get_string()
    return

# iinf: extra information about selected items
class ItemInfoBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @entryCount = bits.read_bits 16

    @children = []
    for i in [1..@entryCount]
      box = Box.parse bits, this
      @children.push box
    return

# ilst: list of actual metadata values
class MetadataItemListBox extends Container

class GenericDataBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @length = bits.read_uint32()
    @name = bits.read_bytes(4).toString 'utf8'
    @entryCount = bits.read_uint32()
    zeroBytes = bits.read_bytes_sum 4
    if zeroBytes isnt 0
      logger.warn "[mp4] warning: zeroBytes are not all zeros (got #{zeroBytes})"
    @value = bits.read_bytes(@length - 16)
    nullPos = Bits.searchByteInBuffer @value, 0x00
    if nullPos is 0
      @valueStr = null
    else if nullPos isnt -1
      @valueStr = @value[0...nullPos].toString 'utf8'
    else
      @valueStr = @value.toString 'utf8'
    return

  getDetails: (detailLevel) ->
    return "#{@name}=#{@valueStr}"

  getTree: ->
    obj = new Box
    obj.data = @valueStr
    return obj

# gsst: unknown
class GoogleGSSTBox extends GenericDataBox

# gstd: unknown
class GoogleGSTDBox extends GenericDataBox

# gssd: unknown
class GoogleGSSDBox extends GenericDataBox

# gspu: unknown
class GoogleGSPUBox extends GenericDataBox

# gspm: unknown
class GoogleGSPMBox extends GenericDataBox

# gshh: unknown
class GoogleGSHHBox extends GenericDataBox

# Media Data Box (mdat): audio/video frames
# Defined in ISO 14496-12
class MediaDataBox extends Box
  read: (buf) ->
    # We will not parse the raw media stream

# avc1
# Defined in ISO 14496-15
class AVCSampleEntry extends VisualSampleEntry
  read: (buf) ->
    super buf
    bits = new Bits @remaining_buf
    @children = []
    @children.push Box.parse bits, this, AVCConfigurationBox
    if bits.has_more_data()
      @children.push Box.parse bits, this, MPEG4BitRateBox
    if bits.has_more_data()
      @children.push Box.parse bits, this, MPEG4ExtensionDescriptorsBox
    return

# btrt
# Defined in ISO 14496-15
class MPEG4BitRateBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @bufferSizeDB = bits.read_uint32()
    @maxBitrate = bits.read_uint32()
    @avgBitrate = bits.read_uint32()

  getDetails: (detailLevel) ->
    "bufferSizeDB=#{@bufferSizeDB} maxBitrate=#{@maxBitrate} avgBitrate=#{@avgBitrate}"

  getTree: ->
    obj = new Box
    obj.bufferSizeDB = @bufferSizeDB
    obj.maxBitrate = @maxBitrate
    obj.avgBitrate = @avgBitrate
    return obj

# m4ds
# Defined in ISO 14496-15
class MPEG4ExtensionDescriptorsBox
  read: (buf) ->
    # TODO: implement this?

# avcC
# Defined in ISO 14496-15
class AVCConfigurationBox extends Box
  read: (buf) ->
    bits = new Bits buf

    # AVCDecoderConfigurationRecord
    @configurationVersion = bits.read_byte()
    if @configurationVersion isnt 1
      logger.warn "warning: mp4: avcC: unknown configurationVersion: #{@configurationVersion}"
    @AVCProfileIndication = bits.read_byte()
    @profileCompatibility = bits.read_byte()
    @AVCLevelIndication = bits.read_byte()
    reserved = bits.read_bits 6
#    if reserved isnt 0b111111  # XXX: not always 0b111111?
#      throw new Error "AVCConfigurationBox: reserved-1 is not #{0b111111} (got #{reserved})"
    @lengthSizeMinusOne = bits.read_bits 2
    reserved = bits.read_bits 3
#    if reserved isnt 0b111  # XXX: not always 0b111?
#      throw new Error "AVCConfigurationBox: reserved-2 is not #{0b111} (got #{reserved})"

    # SPS
    @numOfSequenceParameterSets = bits.read_bits 5
    @sequenceParameterSets = []
    for i in [0...@numOfSequenceParameterSets]
      sequenceParameterSetLength = bits.read_bits 16
      @sequenceParameterSets.push bits.read_bytes sequenceParameterSetLength

    # PPS
    @numOfPictureParameterSets = bits.read_byte()
    @pictureParameterSets = []
    for i in [0...@numOfPictureParameterSets]
      pictureParameterSetLength = bits.read_bits 16
      @pictureParameterSets.push bits.read_bytes pictureParameterSetLength

    return

  getDetails: (detailLevel) ->
    'sps=' + @sequenceParameterSets.map((sps) ->
      "0x#{sps.toString 'hex'}"
    ).join(',') + ' pps=' + @pictureParameterSets.map((pps) ->
      "0x#{pps.toString 'hex'}"
    ).join(',')

  getTree: ->
    obj = new Box
    obj.sps = @sequenceParameterSets.map((sps) -> [sps...])
    obj.pps = @pictureParameterSets.map((pps) -> [pps...])
    return obj

# esds
class ESDBox extends Box
  readDecoderConfigDescriptor: (bits) ->
    info = {}
    info.tag = bits.read_byte()
    if info.tag isnt 0x04  # 0x04 == DecoderConfigDescrTag
      throw new Error "ESDBox: DecoderConfigDescrTag is not 4 (got #{info.tag})"
    info.length = @readDescriptorLength bits
    info.objectProfileIndication = bits.read_byte()
    info.streamType = bits.read_bits 6
    info.upStream = bits.read_bit()
    reserved = bits.read_bit()
    if reserved isnt 1
      throw new Error "ESDBox: DecoderConfigDescriptor: reserved bit is not 1 (got #{reserved})"
    info.bufferSizeDB = bits.read_bits 24
    info.maxBitrate = bits.read_uint32()
    info.avgBitrate = bits.read_uint32()
    info.decoderSpecificInfo = @readDecoderSpecificInfo bits
    return info

  readDecoderSpecificInfo: (bits) ->
    info = {}
    info.tag = bits.read_byte()
    if info.tag isnt 0x05  # 0x05 == DecSpecificInfoTag
      throw new Error "ESDBox: DecSpecificInfoTag is not 5 (got #{info.tag})"
    info.length = @readDescriptorLength bits
    info.specificInfo = bits.read_bytes info.length
    return info

  readSLConfigDescriptor: (bits) ->
    info = {}
    info.tag = bits.read_byte()
    if info.tag isnt 0x06  # 0x06 == SLConfigDescrTag
      throw new Error "ESDBox: SLConfigDescrTag is not 6 (got #{info.tag})"
    info.length = @readDescriptorLength bits
    info.predefined = bits.read_byte()
    if info.predefined is 0
      info.useAccessUnitStartFlag = bits.read_bit()
      info.useAccessUnitEndFlag = bits.read_bit()
      info.useRandomAccessPointFlag = bits.read_bit()
      info.hasRandomAccessUnitsOnlyFlag = bits.read_bit()
      info.usePaddingFlag = bits.read_bit()
      info.useTimeStampsFlag = bits.read_bit()
      info.useIdleFlag = bits.read_bit()
      info.durationFlag = bits.read_bit()
      info.timeStampResolution = bits.read_uint32()
      info.ocrResolution = bits.read_uint32()
      info.timeStampLength = bits.read_byte()
      if info.timeStampLength > 64
        throw new Error "ESDBox: SLConfigDescriptor: timeStampLength must be <= 64 (got #{info.timeStampLength})"
      info.ocrLength = bits.read_byte()
      if info.ocrLength > 64
        throw new Error "ESDBox: SLConfigDescriptor: ocrLength must be <= 64 (got #{info.ocrLength})"
      info.auLength = bits.read_byte()
      if info.auLength > 32
        throw new Error "ESDBox: SLConfigDescriptor: auLength must be <= 64 (got #{info.auLength})"
      info.instantBitrateLength = bits.read_byte()
      info.degradationPriorityLength = bits.read_bits 4
      info.auSeqNumLength = bits.read_bits 5
      if info.auSeqNumLength > 16
        throw new Error "ESDBox: SLConfigDescriptor: auSeqNumLength must be <= 16 (got #{info.auSeqNumLength})"
      info.packetSeqNumLength = bits.read_bits 5
      if info.packetSeqNumLength > 16
        throw new Error "ESDBox: SLConfigDescriptor: packetSeqNumLength must be <= 16 (got #{info.packetSeqNumLength})"
      reserved = bits.read_bits 2
      if reserved isnt 0b11
        throw new Error "ESDBox: SLConfigDescriptor: reserved bits value is not #{0b11} (got #{reserved})"

      if info.durationFlag is 1
        info.timeScale = bits.read_uint32()
        info.accessUnitDuration = bits.read_bits 16
        info.compositionUnitDuration = bits.read_bits 16
      if info.useTimeStampsFlag is 0
        info.startDecodingTimeStamp = bits.read_bits info.timeStampLength
        info.startCompositionTimeStamp = bits.read_bits info.timeStamplength
    return info

  readDescriptorLength: (bits) ->
    len = bits.read_byte()
    # TODO: Is this correct?
    if len >= 0x80
      len = ((len & 0x7f) << 21) |
        ((bits.read_byte() & 0x7f) << 14) |
        ((bits.read_byte() & 0x7f) << 7) |
        bits.read_byte()
    return len

  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    # ES_Descriptor (defined in ISO 14496-1)
    @tag = bits.read_byte()
    if @tag isnt 0x03  # 0x03 == ES_DescrTag
      throw new Error "ESDBox: tag is not #{0x03} (got #{@tag})"
    @length = @readDescriptorLength bits
    @ES_ID = bits.read_bits 16
    @streamDependenceFlag = bits.read_bit()
    @urlFlag = bits.read_bit()
    @ocrStreamFlag = bits.read_bit()
    @streamPriority = bits.read_bits 5
    if @streamDependenceFlag is 1
      @depenedsOnES_ID = bits.read_bits 16
    if @urlFlag is 1
      @urlLength = bits.read_byte()
      @urlString = bits.read_bytes(@urlLength)
    if @ocrStreamFlag is 1
      @ocrES_ID = bits.read_bits 16

    @decoderConfigDescriptor = @readDecoderConfigDescriptor bits

    # TODO: if ODProfileLevelIndication is 0x01

    @slConfigDescriptor = @readSLConfigDescriptor bits

    # TODO:
    # IPI_DescPointer
    # IP_IdentificationDataSet
    # IPMP_DescriptorPointer
    # LanguageDescriptor
    # QoS_Descriptor
    # RegistrationDescriptor
    # ExtensionDescriptor

    return

  getDetails: (detailLevel) ->
    "audioSpecificConfig=0x#{@decoderConfigDescriptor.decoderSpecificInfo.specificInfo.toString 'hex'} maxBitrate=#{@decoderConfigDescriptor.maxBitrate} avgBitrate=#{@decoderConfigDescriptor.avgBitrate}"

  getTree: ->
    obj = new Box
    obj.audioSpecificConfig = [@decoderConfigDescriptor.decoderSpecificInfo.specificInfo...]
    obj.maxBitrate = @decoderConfigDescriptor.maxBitrate
    obj.avgBitrate = @decoderConfigDescriptor.avgBitrate
    return obj

# mp4a
# Defined in ISO 14496-14
class MP4AudioSampleEntry extends AudioSampleEntry
  read: (buf) ->
    super buf
    bits = new Bits @remaining_buf
    @children = [
      Box.parse bits, this, ESDBox
    ]
    return

# free: can be ignored
# Defined in ISO 14496-12
class FreeSpaceBox extends Box

# ctts: offset between decoding time and composition time
class CompositionOffsetBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @entryCount = bits.read_uint32()
    @entries = []
    for i in [0...@entryCount]
      sampleCount = bits.read_uint32()
      sampleOffset = bits.read_uint32()
      @entries.push
        sampleCount: sampleCount
        sampleOffset: sampleOffset
    return

  # sampleNumber is indexed from 1
  getCompositionTimeOffset: (sampleNumber) ->
    for entry in @entries
      if sampleNumber <= entry.sampleCount
        return entry.sampleOffset
      sampleNumber -= entry.sampleCount
    throw new Error "mp4: ctts: composition time for sample number #{sampleNumber} not found"

# '\xa9too' (copyright sign + 'too')
class CTOOBox extends GenericDataBox


api =
  MP4File: MP4File

module.exports = api
