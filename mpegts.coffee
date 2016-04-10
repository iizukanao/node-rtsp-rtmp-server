# MPEG-TS parser

fs = require 'fs'
Bits = require './bits'
logger = require './logger'

TS_PACKET_SIZE = 188
SYNC_BYTE = 0x47

PES_STREAM_ID_PROGRAM_STREAM_MAP              = 188
PES_STREAM_ID_PRIVATE_STREAM_1                = 189
PES_STREAM_ID_PADDING_STREAM                  = 190
PES_STREAM_ID_PRIVATE_STREAM_2                = 191
PES_STREAM_ID_ECM                             = 240
PES_STREAM_ID_EMM                             = 241
PES_STREAM_ID_PROGRAM_STREAM_DIRECTORY        = 255
PES_STREAM_ID_DSMCC_STREAM                    = 242
PES_STREAM_ID_ITU_T_REC_H_222_1_TYPE_E_STREAM = 248

TRICK_MODE_CONTROL_FAST_FORWARD = 0
TRICK_MODE_CONTROL_SLOW_MOTION  = 1
TRICK_MODE_CONTROL_FREEZE_FRAME = 2
TRICK_MODE_CONTROL_FAST_REVERSE = 3
TRICK_MODE_CONTROL_SLOW_REVERSE = 4

PID_PROGRAM_ASSOCIATION_TABLE          = 0x0000
PID_CONDITIONAL_ACCESS_TABLE           = 0x0001
PID_TRANSPORT_STREAM_DESCRIPTION_TABLE = 0x0002
PID_IPMP_CONTROL_INFORMATION_TABLE     = 0x0003
PID_DVB_NIT_ST                         = 0x0010
PID_NULL_PACKET                        = 0x1FFF

STREAM_TYPE_MPEG2_VIDEO       = 0x02  # MPEG-2 video
STREAM_TYPE_MPEG2_PES_PRIVATE = 0x06  # PES packets containing private data
STREAM_TYPE_MPEG2_DSM_CC      = 0x0D
STREAM_TYPE_AUDIO_ADTS        = 0x0F
STREAM_TYPE_H264              = 0x1B  # AVC video

MAX_PES_PAYLOAD_SIZE = 200 * 1024

SETTIMEOUT_ADVANCE_TIME = 20

tsBits = null
tsBuf = null
isSyncByteDetermined = false
programTable = {}
programMap = {}
unparsedPESPackets = []
audioPID = null
videoPID = null
pendingVideoPesPackets = []
pendingAudioPesPackets = []
streamingStartTime = null
firstDTS = null
bufferingPESData = {}
isEOF = false

eventListeners = {}

api =
  open: (file) ->
    tsBuf = fs.readFileSync file  # up to 1GB

  close: ->
    tsBuf = null

  emit: (name, data...) ->
    if eventListeners[name]?
      for listener in eventListeners[name]
        listener data...
    return

  on: (name, listener) ->
    if eventListeners[name]?
      eventListeners[name].push listener
    else
      eventListeners[name] = [ listener ]

  startStreaming: (initialSkipTimeMs=0) ->
    @resetState()
    tsBits = new Bits tsBuf
    streamingStartTime = Date.now() - initialSkipTimeMs
    @readNext()

  resetState: ->
    unparsedPESPackets = []
    streamingStartTime = null
    bufferingPESData = {}
    isEOF = false
    isSyncByteDetermined = false
    firstPTS = null

  pts2ms: (pts) ->
    pts / 90

  getTimeUntilDTS: (dts) ->
    if not firstDTS?
      throw new Error "not yet received the first video or audio packet"
    return streamingStartTime + (dts - firstDTS) / 90 - Date.now()

  getCurrentPTS: ->
    (Date.now() - streamingStartTime) * 90

  checkEnd: ->
    if isEOF and (pendingAudioPesPackets.length is 0) and
    (pendingVideoPesPackets.length is 0)
      @emit 'end'
      return true
    return false

  consumeVideo: (doNotReadNext=false) ->
    pendingLen = pendingVideoPesPackets.length
    if pendingLen > 0
      pesInfo = pendingVideoPesPackets.shift()
      @emit 'video', pesInfo
      if pendingLen is 1  # now the buffer is empty
        if (not doNotReadNext) and (not @checkEnd())
          @readNext()
      else
        timeDiff = Math.round @getTimeUntilDTS(pendingVideoPesPackets[0].pes.DTS) - SETTIMEOUT_ADVANCE_TIME
        if timeDiff <= 0
          @consumeVideo doNotReadNext
        else
          setTimeout =>
            @consumeVideo doNotReadNext
          , timeDiff

  consumeAudio: (doNotReadNext=false) ->
    pendingLen = pendingAudioPesPackets.length
    if pendingLen > 0
      pesInfo = pendingAudioPesPackets.shift()
      @emit 'audio', pesInfo
      if pendingLen is 1  # now the buffer is empty
        if (not doNotReadNext) and (not @checkEnd())
          @readNext()
      else
        timeDiff = Math.round @getTimeUntilDTS(pendingAudioPesPackets[0].pes.DTS) - SETTIMEOUT_ADVANCE_TIME
        if timeDiff <= 0
          @consumeAudio doNotReadNext
        else
          setTimeout =>
            @consumeAudio doNotReadNext
          , timeDiff

  queueVideo: (pesInfo, doNotReadNext=false) ->
    pendingVideoPesPackets.push pesInfo
    if pendingVideoPesPackets.length is 1
      timeDiff = Math.round @getTimeUntilDTS(pesInfo.pes.DTS) - SETTIMEOUT_ADVANCE_TIME
      if timeDiff <= 0
        setImmediate =>
          @consumeVideo doNotReadNext
      else
        setTimeout =>
          @consumeVideo doNotReadNext
        , timeDiff

  queueAudio: (pesInfo, doNotReadNext=false) ->
    pendingAudioPesPackets.push pesInfo
    if pendingAudioPesPackets.length is 1
      timeDiff = Math.round @getTimeUntilDTS(pesInfo.pes.DTS) - SETTIMEOUT_ADVANCE_TIME
      if timeDiff <= 0
        setImmediate =>
          @consumeAudio doNotReadNext
      else
        setTimeout =>
          @consumeAudio doNotReadNext
        , timeDiff

  readNext: ->
    pesPacket = @getNextPESPacket()
    if not pesPacket?  # maybe reached EOF
      return
    pesInfo = @parsePESPacket pesPacket.pid, pesPacket.packet, pesPacket.opts
    if pesInfo.program_map?  # received a program map
      # parse and consume unparsedPESPackets
      @consumeUnparsedPESPackets()
    if pesInfo.not_parsed
      # postpone the parsing process after received a program map
      unparsedPESPackets.push pesPacket
    if not pesInfo.pes?  # not an video/audio packet
      # such as program association section or program map section
      return @readNext()
    if not pesInfo.pes.PTS?
      throw new Error "PES packet doesn't have PTS"
    if not pesInfo.pes.DTS?
      pesInfo.pes.DTS = pesInfo.pes.PTS
    if not firstDTS?
      firstDTS = pesInfo.pes.DTS

    if pesInfo.pes.stream_id_type is 'video'
      @queueVideo pesInfo
    else if pesInfo.pes.stream_id_type is 'audio'
      @queueAudio pesInfo

    if (pendingAudioPesPackets.length < 2) or (pendingVideoPesPackets.length < 2)
      @readNext()

  startReading: ->
    api.read_transport_stream tsBuf

  # TODO: Check if old API is no longer used
  # Described in Table 5: Service description section
  read_service_description_section: (bits) ->
    pointer_field = bits.read_byte()
    table_id = bits.read_byte()
    section_syntax_indicator = bits.read_bit()
    if section_syntax_indicator isnt 1
      throw new Error "section_syntax_indicator must be 1"
    reserved_future_use = bits.read_bit()
    reserved = bits.read_bits 2
    section_length = bits.read_bits 12
    if section_length > 0x3ff
      throw new Error "The first two bits of section_length must be 00: #{section_length}"
    transport_stream_id = bits.read_bits 16
    reserved = bits.read_bits 2
    version_number = bits.read_bits 5
    current_next_indicator = bits.read_bit()
    section_number = bits.read_byte()
    last_section_number = bits.read_byte()
    original_network_id = bits.read_bits 16
    reserved_future_use = bits.read_byte()

    remaining_section_length = section_length - 8 - 4  # 4 is for CRC
    while remaining_section_length > 0
      service_id = bits.read_bits 16
      # service_id is the same as the program_number in the corresponding program_map_section
      reserved_future_use = bits.read_bits 6
      EIT_schedule_flag = bits.read_bit()
      EIT_present_following_flag = bits.read_bit()
      running_status = bits.read_bits 3
      free_CA_mode = bits.read_bit()
      descriptors_loop_length = bits.read_bits 12
      remaining_descriptors_loop_length = descriptors_loop_length
      descriptors = []
      while remaining_descriptors_loop_length > 0
        descriptor = api.read_descriptor bits
        descriptors.push descriptor
        remaining_descriptors_loop_length -= descriptor.total_length
      remaining_section_length -= 5 + descriptors_loop_length

    CRC_32 = bits.read_bits 32

  read_CA_descriptor: (bits) ->
    info = {}
    info.descriptor_tag = bits.read_byte()
    info.descriptor_length = bits.read_byte()
    info.CA_system_ID = bits.read_bits 16
    reserved = bits.read_bits 3
    info.CA_PID = bits.read_bits 13
    remainingLen = info.descriptor_length - 4
    info.private_data = bits.read_bytes remainingLen
    return info

  read_ISO_639_language_descriptor: (bits) ->
    info = {}
    info.descriptor_tag = bits.read_byte()
    info.descriptor_length = bits.read_byte()
    # ISO_639_language_descriptor
    num_loops = info.descriptor_length / 4
    info.languages = []
    for i in [0...num_loops]
      ISO_639_language_code = bits.read_bytes(3).toString 'utf-8'
      # "und" means Undetermined
      audio_type = bits.read_byte()
      info.languages.push
        ISO_639_language_code: ISO_639_language_code
        audio_type: audio_type
    return info

  # DVB service_descriptor, described in Table 12 in DVB spec
  read_DVB_service_descriptor: (bits) ->
    info = {}
    info.descriptor_tag = bits.read_byte()
    info.descriptor_length = bits.read_byte()
    info.service_type = bits.read_byte()
    info.service_provider_name_length = bits.read_byte()
    info.service_provider_name = bits.read_bytes(service_provider_name_length).toString 'utf-8'
    info.service_name_length = bits.read_byte()
    info.service_name = bits.read_bytes(service_name_length).toString 'utf-8'
    return info

  read_unknown_descriptor: (bits) ->
    info = {}
    info.descriptor_tag = bits.read_byte()
    info.descriptor_length = bits.read_byte()
    bits.skip_bytes info.descriptor_length
    return info

  read_DVB_stream_identifier_descriptor: (bits) ->
    info = {}
    info.descriptor_tag = bits.read_byte()
    info.descriptor_length = bits.read_byte()
    info.component_tag = bits.read_byte()
    return info

  # Described in Section 2.6
  read_descriptor: (bits) ->
    descriptor_tag = bits.read_byte()
    bits.push_back_byte()
    # descriptor_tag table is described in Table 2-45
    info = switch descriptor_tag
      when 9 then api.read_CA_descriptor bits
      when 10 then api.read_ISO_639_language_descriptor bits
      when 0x48 then api.read_DVB_service_descriptor bits  # 72
      when 0x52 then api.read_DVB_stream_identifier_descriptor bits  # 82
      when 193, 200, 246, 253 then api.read_unknown_descriptor bits
      else
        throw new Error "descriptor_tag #{descriptor_tag} is not implemented"
    info.total_length = info.descriptor_length + 2
    return info

  # Described in Table 2-33
  read_program_map_section: (bits) ->
    info = {}
    info.pointer_field = bits.read_byte()
    bits.skip_bytes info.pointer_field
    info.table_id = bits.read_byte()
    if info.table_id isnt 2
      throw new Error "table_id must be 2: #{info.table_id}"
    info.section_syntax_indicator = bits.read_bit()
    if info.section_syntax_indicator isnt 1
      throw new Error "section_syntax_indicator must be 1: #{info.section_syntax_indicator}"
    bit_0 = bits.read_bit()
    if bit_0 isnt 0
      throw new Error "bit_0 must be 0: #{bit_0}"
    reserved = bits.read_bits 2
    info.section_length = bits.read_bits 12
    info.program_number = bits.read_bits 16
    reserved = bits.read_bits 2
    info.version_number = bits.read_bits 5
    info.current_next_indicator = bits.read_bit()
    info.section_number = bits.read_byte()
    if info.section_number isnt 0
      throw new Error "section_number must be 0: #{section_number}"
    info.last_section_number = bits.read_byte()
    if info.last_section_number isnt 0
      throw new Error "last_section_number must be 0: #{last_section_number}"
    reserved = bits.read_bits 3
    info.PCR_PID = bits.read_bits 13
    reserved = bits.read_bits 4
    info.program_info_length = bits.read_bits 12
    if info.program_info_length > 0x3ff
      throw new Error "The first two bits of program_info_length must be 00: #{info.program_info_length}"
    remaining_program_info_length = info.program_info_length
    info.descriptors = []
    while remaining_program_info_length > 0
      descriptor = api.read_descriptor bits
      info.descriptors.push descriptor
      remaining_program_info_length -= descriptor.total_length

    remaining_section_length = info.section_length - 9 - info.program_info_length - 4  # 4 for CRC
    info.streams = []
    while remaining_section_length > 0
      stream_type = bits.read_byte()
      reserved = bits.read_bits 3
      elementary_PID = bits.read_bits 13
      switch stream_type
        when STREAM_TYPE_H264
          videoPID = elementary_PID
        when STREAM_TYPE_AUDIO_ADTS
          audioPID = elementary_PID
      reserved = bits.read_bits 4
      ES_info_length = bits.read_bits 12
      remaining_ES_info_length = ES_info_length
      descriptors = []
      while remaining_ES_info_length > 0
        descriptor = api.read_descriptor bits
        descriptors.push descriptor
        remaining_ES_info_length -= descriptor.total_length
      remaining_section_length -= 5 + ES_info_length
      info.streams.push
        stream_type: stream_type
        elementary_PID: elementary_PID
        ES_info_length: ES_info_length
        descriptors: descriptors

    CRC_32 = bits.read_bits 32

    return info

  # Described in Table-2-29 and Table 2-30
  read_program_association_section: (bits) ->
    info = {}
    info.pointer_field = bits.read_byte()
    info.table_id = bits.read_byte()
    if info.table_id isnt 0x00
      throw new Error "table_id for program_association_section must be 0x00"
    info.section_syntax_indicator = bits.read_bit()
    if info.section_syntax_indicator isnt 1
      throw new Error "section_syntax_indicator must be 1: #{info.section_syntax_indicator}"
    bit_0 = bits.read_bit()
    if bit_0 isnt 0
      throw new Error "bit_0 must be 0: #{bit_0}"
    reserved = bits.read_bits 2
    info.section_length = bits.read_bits 12
    if info.section_length > 1021
      throw new Error "section_length shall not exceed 1021 (0x3FD)"
    info.transport_stream_id = bits.read_bits 16
    reserved = bits.read_bits 2
    info.version_number = bits.read_bits 5
    info.current_next_indicator = bits.read_bit()
    info.section_number = bits.read_byte()
    info.last_section_number = bits.read_byte()

    num_programs = (info.section_length - 9) / 4
    info.programTable = {}
    for i in [0...num_programs]
      program_number = bits.read_bits 16
      reserved  = bits.read_bits 3
      if program_number is 0
        info.programTable[program_number] =
          network_PID: bits.read_bits 13
      else
        info.programTable[program_number] =
          program_map_PID: bits.read_bits 13
    programTable = info.programTable

    CRC_32 = bits.read_bits 32

    return info

  consumeUnparsedPESPackets: ->
    for pesPacket in unparsedPESPackets
      pesInfo = @parsePESPacket pesPacket.pid, pesPacket.packet, pesPacket.opts
      if pesInfo.not_parsed
        continue
      if not pesInfo.pes?  # not an video/audio packet
        continue
      if not pesInfo.pes.PTS?
        throw new Error "PES packet doesn't have PTS"
      if not pesInfo.pes.DTS?
        pesInfo.pes.DTS = pesInfo.pes.PTS
      if not firstDTS?
        firstDTS = pesInfo.pes.DTS

      if pesInfo.pes.stream_id_type is 'video'
        @queueVideo pesInfo, true
      else if pesInfo.pes.stream_id_type is 'audio'
        @queueAudio pesInfo, true
    unparsedPESPackets = []

  parsePESPacket: (pid, packet, opts) ->
    info = {}

    pes_data = Buffer.concat packet.data

    # Described in Table 2-3 - PID table
    switch pid
      when PID_PROGRAM_ASSOCIATION_TABLE  # 0
        bits = new Bits pes_data
        info.program_association = api.read_program_association_section bits
      when videoPID, audioPID
        bits = new Bits pes_data
        if not opts?
          opts = {}
        opts.pid = pid
        info.pes = api.read_pes_packet bits, opts
      else
        isParsed = false
        for programNumber, pidInfo of programTable
          if pid is pidInfo.program_map_PID
            bits = new Bits pes_data
            info.program_map = api.read_program_map_section bits
            programMap = info.program_map
            isParsed = true
        if not isParsed
          info.not_parsed = true
    return info

  read_system_header: (bits) ->
    info = {}
    system_header_start_code = bits.read_bits 32
    if system_header_start_code isnt 0x000001BB
      throw new Error "system_header_start_code must be 0x000001BB"
    info.header_length = bits.read_bits 16
    marker_bit = bits.read_bit()
    info.rate_bound = bits.read_bits 22
    marker_bit = bits.read_bit()
    info.audio_bound = bits.read_bits 6
    info.fixed_flag = bits.read_bit()
    info.CSPS_flag = bits.read_bit()
    info.system_audio_lock_flag = bits.read_bit()
    info.system_video_lock_flag = bits.read_bit()
    marker_bit = bits.read_bit()
    info.video_bound = bits.read_bits 5
    info.packet_rate_restriction_flag = bits.read_bit()
    reserved_bits = bits.read_bits 7
    info.total_length = 12
    info.bufferBounds = {}
    while ((nextByte = bits.read_byte()) & 0x80) is 0x80
      stream_id = nextByte
      bits_11 = bits.read_bits 2
      if bits_11 isnt 3
        throw new Error "bits must be '11': #{bits_11}"
      P_STD_buffer_bound_scale = bits.read_bit()
      P_STD_buffer_size_bound = bits.read_bits 13
      info.bufferBounds[stream_id] =
        P_STD_buffer_bound_scale: P_STD_buffer_bound_scale
        P_STD_buffer_size_bound: P_STD_buffer_size_bound
      info.total_length += 3
    bits.push_back_byte()
    return info

  # pack_header()
  read_pack_header: (bits) ->
    info = {}
    pack_start_code = bits.read_bits 32
    if pack_start_code isnt 0x000001BA
      throw new Error "pack_start_code must be 0x000001BA"
    bits_01 = bits.read_bits 2
    if bits_01 isnt 1
      throw new Error "bits must be '01': #{bits_01}"
    info.system_clock_reference_base = bits.read_bits(3) * Math.pow(2, 30)
    marker_bit = bits.read_bit()
    info.system_clock_reference_base += bits.read_bits(15) * Math.pow(2, 15)
    marker_bit = bits.read_bit()
    info.system_clock_reference_base += bits.read_bits(15)
    marker_bit = bits.read_bit()
    info.system_clock_reference_extension = bits.read_bits 9
    marker_bit = bits.read_bit()
    info.program_mux_rate = bits.read_bits 22
    marker_bit = bits.read_bit()
    marker_bit = bits.read_bit()
    reserved = bits.read_bits 5
    info.pack_stuffing_length = bits.read_bits 3

    # skip stuffing bytes
    bits.skip_bytes info.pack_stuffing_length

    info.total_length = 14 + info.pack_stuffing_length

    # check if system_header() exists
    system_header_start_code = bits.read_bits 32
    if system_header_start_code is 0x000001BB
      bits.push_back_bits 32
      info.system_header = api.read_system_header bits
      info.total_length += info.system_header.total_length

    return info

  # PES_packet()
  read_pes_packet: (bits, opts) ->
    info = {}
    # Start code emulation is not possible in video elementary streams.
    # It is possible in audio and data elementary streams.
    packet_start_code_prefix = bits.read_bits 24  # must be 0x000001
    if packet_start_code_prefix isnt 0x000001
      bits.push_back_bytes 3
      bits.peek()
      bits.print_position()
      throw new Error "packet_start_code_prefix must be 0x000001: #{packet_start_code_prefix}"
    info.stream_id = bits.read_byte()

    # PES_packet_length is the length between the last byte of
    # PES_packet_length and the first byte of PES_packet_data.
    info.PES_packet_length = bits.read_bits 16  # do not use read_bytes(2)!
    remaining_pes_len = info.PES_packet_length

    # PES_packet_length == 0 indicates that the PES packet length is unbounded.
    # Unbounded length is allowed only for video elementary streams because
    # start code emulation (false positive) is prevented in video streams.
    if info.PES_packet_length is 0
      remaining_pes_len = MAX_PES_PAYLOAD_SIZE

    if info.stream_id not in [
      PES_STREAM_ID_PROGRAM_STREAM_MAP
      PES_STREAM_ID_PADDING_STREAM
      PES_STREAM_ID_PRIVATE_STREAM_2
      PES_STREAM_ID_ECM
      PES_STREAM_ID_EMM
      PES_STREAM_ID_PROGRAM_STREAM_DIRECTORY
      PES_STREAM_ID_DSMCC_STREAM
      PES_STREAM_ID_ITU_T_REC_H_222_1_TYPE_E_STREAM
    ]
      bits_10 = bits.read_bits 2
      if bits_10 isnt 2
        throw new Error "bits must be '10': #{bits_10}"
      info.PES_scrambling_control = bits.read_bits 2
      info.PES_priority = bits.read_bit()
      info.data_alignment_indicator = bits.read_bit()
      info.copyright = bits.read_bit()
      info.original_or_copy = bits.read_bit()
      info.PTS_DTS_flags = bits.read_bits 2
      info.ESCR_flag = bits.read_bit()
      info.ES_rate_flag = bits.read_bit()
      info.DSM_trick_mode_flag = bits.read_bit()
      info.additional_copy_info_flag = bits.read_bit()
      info.PES_CRC_flag = bits.read_bit()
      info.PES_extension_flag = bits.read_bit()
      info.PES_header_data_length = bits.read_byte()
      remaining_header_len = info.PES_header_data_length
      remaining_pes_len -= 3

      if info.PTS_DTS_flags is 2
        bits_0010 = bits.read_bits 4
        if bits_0010 isnt 2
          throw new Error "Bits must be '0010': #{bits_0010}"
        info.PTS = bits.read_bits(3) * Math.pow(2, 30)
        marker_bit = bits.read_bit()
        info.PTS += bits.read_bits(15) * Math.pow(2, 15)
        marker_bit = bits.read_bit()
        info.PTS += bits.read_bits(15)

        marker_bit = bits.read_bit()
        remaining_pes_len -= 5
        remaining_header_len -= 5
      if info.PTS_DTS_flags is 3
        bits_0011 = bits.read_bits 4
        if bits_0011 isnt 3
          throw new Error "Bits must be '0011': #{bits_0011}"
        info.PTS = bits.read_bits(3) * Math.pow(2, 30)
        marker_bit = bits.read_bit()
        info.PTS += bits.read_bits(15) * Math.pow(2, 15)
        marker_bit = bits.read_bit()
        info.PTS += bits.read_bits(15)
        marker_bit = bits.read_bit()
        bits_0001 = bits.read_bits 4
        if bits_0001 isnt 1
          throw new Error "Bits must be '0001': #{bits_0001}"
        info.DTS = bits.read_bits(3) * Math.pow(2, 30)
        marker_bit = bits.read_bit()
        info.DTS += bits.read_bits(15) * Math.pow(2, 15)
        marker_bit = bits.read_bit()
        info.DTS += bits.read_bits(15)

        marker_bit = bits.read_bit()
        remaining_pes_len -= 10
        remaining_header_len -= 10

      if info.ESCR_flag is 1
        reserved = bits.read_bits 2
        info.ESCR_base = bits.read_bits(3) * Math.pow(2, 30)
        marker_bit = bits.read_bit()
        info.ESCR_base += bits.read_bits(15) * Math.pow(2, 15)
        marker_bit = bits.read_bit()
        info.ESCR_base += bits.read_bits(15)
        marker_bit = bits.read_bit()
        info.ESCR_extension = bits.read_bits 9
        marker_bit = bits.read_bit()
        remaining_pes_len -= 6
        remaining_header_len -= 6

      if info.ES_rate_flag is 1
        marker_bit = bits.read_bit()
        info.ES_rate = bits.read_bits 22
        marker_bit = bits.read_bit()
        remaining_pes_len -= 3
        remaining_header_len -= 3

      if info.DSM_trick_mode_flag is 1
        info.trick_mode_control = bits.read_bits 3
        if info.trick_mode_control is TRICK_MODE_CONTROL_FAST_FORWARD
          info.field_id = bits.read_bits 2
          info.intra_slice_refresh = bits.read_bit()
          info.frequency_truncation = bits.read_bits 2
        else if info.trick_mode_control is TRICK_MODE_CONTROL_SLOW_MOTION
          info.rep_cntrl = bits.read_bits 5
        else if info.trick_mode_control is TRICK_MODE_CONTROL_FREEZE_FRAME
          info.field_id = bits.read_bits 2
          reserved = bits.read_bits 3
        else if info.trick_mode_control is TRICK_MODE_CONTROL_FAST_REVERSE
          info.field_id = bits.read_bits 2
          info.intra_slice_refresh = bits.read_bit()
          info.frequency_truncation = bits.read_bits 2
        else if info.trick_mode_control is TRICK_MODE_CONTROL_SLOW_REVERSE
          info.rep_cntrl = bits.read_bits 5
        else
          reserved = bits.read_bits 5
        remaining_pes_len--
        remaining_header_len--

      if info.additional_copy_info_flag is 1
        marker_bit = bits.read_bit()
        info.additional_copy_info = bits.read_bits 7
        remaining_pes_len--
        remaining_header_len--

      if info.PES_CRC_flag is 1
        info.previous_PES_packet_CRC = bits.read_bits 16
        remaining_pes_len -= 2
        remaining_header_len -= 2
      if info.PES_extension_flag is 1
        info.PES_private_data_flag = bits.read_bit()
        info.pack_header_field_flag = bits.read_bit()
        info.program_packet_sequence_counter_flag = bits.read_bit()
        info.P_STD_buffer_flag = bits.read_bit()
        reserved = bits.read_bits 3
        info.PES_extension_flag_2 = bits.read_bit()
        remaining_pes_len--
        remaining_header_len--
        if info.PES_private_data_flag is 1
          info.PES_private_data = bits.read_bytes 16
          remaining_pes_len -= 16
          remaining_header_len -= 16
        if info.pack_header_field_flag is 1
          info.pack_field_length = bits.read_byte()
          info.pack_header = api.read_pack_header bits
          remaining_pes_len -= info.pack_header.total_length
          remaining_header_len -= info.pack_header.total_length
        if info.program_packet_sequence_counter_flag is 1
          marker_bit = bits.read_bit()
          info.program_packet_sequence_counter = bits.read_bits 7
          marker_bit = bits.read_bit()
          info.MPEG1_MPEG2_identifier = bits.read_bit()
          info.original_stuff_length = bits.read_bits 6
          remaining_pes_len -= 2
          remaining_header_len -= 2
        if info.P_STD_buffer_flag is 1
          bits_01 = bits.read_bits 2
          if bits_01 isnt 1
            throw new Error "bits must be '01': #{bits_01}"
          info.P_STD_buffer_scale = bits.read_bit()
          info.P_STD_buffer_size = bits.read_bits 13
          remaining_pes_len -= 2
          remaining_header_len -= 2
        if info.PES_extension_flag_2 is 1
          marker_bit = bits.read_bit()
          info.PES_extension_field_length = bits.read_bits 7
          info.stream_id_extension_flag = bits.read_bit()
          if info.stream_id_extension_flag is 0
            info.stream_id_extension = bits.read_bits 7
            bits.skip_bytes info.PES_extension_field_length  # reserved
            remaining_pes_len -= 2 + info.PES_extension_field_length
            remaining_header_len -= 2 + info.PES_extension_field_length
          else
            throw new Error "stream_id_extension_flag == 1 is reserved"

      # skip stuffing bytes
      bits.skip_bytes remaining_header_len
      remaining_pes_len -= remaining_header_len

      # content
      PES_packet_data_byte = bits.read_bytes remaining_pes_len, 1
      info.data = PES_packet_data_byte

      if (info.stream_id & 0b11110000) is 0b11100000  # video stream
        info.stream_id_type = 'video'
      else if (info.stream_id & 0b11100000) is 0b11000000  # audio stream
        info.stream_id_type = 'audio'

    else if info.stream_id in [
      PES_STREAM_ID_PROGRAM_STREAM_MAP
      PES_STREAM_ID_PRIVATE_STREAM_2
      PES_STREAM_ID_ECM
      PES_STREAM_ID_EMM
      PES_STREAM_ID_PROGRAM_STREAM_DIRECTORY
      PES_STREAM_ID_DSMCC_STREAM
      PES_STREAM_ID_ITU_T_REC_H_222_1_TYPE_E_STREAM
    ]
      throw new Error "stream_id type 2"
      PES_packet_data_byte = bits.read_bytes remaining_pes_len, 1
      info.data = PES_packet_data_byte
    else if (info.stream_id is PES_STREAM_ID_PADDING_STREAM)
      throw new Error "stream_id type padding"
      padding_byte = bits.read_bytes remaining_pes_len, 1 # all 0xff

    return info

  # Sync byte (0x47) may occur within data byte.
  # It appears that there is no emulation mechanism in MPEG-TS level.
  # According to the spec, emulation of the sync byte is permitted
  # to occur in the same position of the packet header for a maximum of
  # 4-consecutive transport packets, though this is a recommendation.
  search_sync_byte: (bits) ->
    if isSyncByteDetermined
      if not bits.is_byte_aligned()
        throw new Error "search_sync_byte: byte is not aligned"
      if bits.get_current_byte() isnt SYNC_BYTE
        throw new Error "sync byte must be here: #{bits.get_current_byte()}"
    else
      read_len = 0
      loop
        if bits.read_byte() is SYNC_BYTE
          # Check if 5 consecutive transport packets have
          # sync byte at the same position.
          for i in [1..4]
            if bits.get_byte_at(i * TS_PACKET_SIZE - 1) isnt SYNC_BYTE
              logger.debug "mpegts: sync byte was false positive"
              # false positive (sync byte emulation)
              continue
          isSyncByteDetermined = true
          if read_len > 0
            logger.debug "mpegts: skipped #{read_len} bytes before sync byte"
          bits.push_back_bytes 1
          return
        read_len++

  read_adaptation_field: (bits) ->
    info = {}
    info.adaptation_field_length = bits.read_byte()
    consumed_bytes = 0

    if info.adaptation_field_length > 0
      info.discontinuity_indicator = bits.read_bit()
      info.random_access_indicator = bits.read_bit()
      info.elementary_stream_priority_indicator = bits.read_bit()
      info.pcr_flag = bits.read_bit()
      info.opcr_flag = bits.read_bit()
      info.splicing_point_flag = bits.read_bit()
      info.transport_private_data_flag = bits.read_bit()
      info.adaptation_field_extension_flag = bits.read_bit()
      consumed_bytes++

      if info.pcr_flag is 1
        info.program_clock_reference_base = bits.read_bits 33
        reserved = bits.read_bits 6
        info.program_clock_reference_extension = bits.read_bits 9
        consumed_bytes += 6

      if info.opcr_flag is 1
        info.original_program_clock_reference_base = bits.read_bits 33
        reserved = read_bits 6
        info.original_program_clock_reference_extension = bits.read_bits 9
        consumed_bytes += 6

      if info.splicing_point_flag is 1
        info.splice_countdown = bits.read_byte()
        consumed_bytes++

      if info.transport_private_data_flag is 1
        transport_private_data_length = bits.read_byte()
        consumed_bytes++
        info.private_data = bits.read_bytes transport_private_data_length
        consumed_bytes += transport_private_data_length

      if info.adaptation_field_extension_flag is 1
        info.adaptation_field_extension_length = bits.read_byte()
        info.ltw_flag = bits.read_bit()
        info.piecewise_rate_flag = bits.read_bit()
        info.seamless_splice_flag = bits.read_bit()
        reserved = bits.read_bits 5
        consumed_bytes += 2

        if info.ltw_flag is 1
          info.ltw_valid_flag = bits.read_bit()
          info.ltw_offset = bits.read_bits 15
          consumed_bytes += 2

        if info.piecewise_rate_flag is 1
          reserved = bits.read_bits 2
          info.piecewise_rate = bits.read_bits 22
          consumed_bytes += 3

        if info.seamless_splice_flag is 1
          info.splice_type = bits.read_bits 4
          info.DTS_next_AU = bits.read_bits(3) * Math.pow(2, 30)
          marker_bit = bits.read_bit()
          info.DTS_next_AU += bits.read_bits(15) * Math.pow(2, 15)
          marker_bit = bits.read_bit()
          info.DTS_next_AU += bits.read_bits(15)
          marker_bit = bits.read_bit()
          consumed_bytes += 5

      # skip stuffing bytes
      bits.skip_bytes info.adaptation_field_length - consumed_bytes

    return info

  # Table 2-2 transport_packet()
  read_transport_packet: (bits) ->
    info = {}
    api.search_sync_byte bits
    sync_byte = bits.read_byte()
    info.transport_error_indicator = bits.read_bit()
    info.payload_unit_start_indicator = bits.read_bit()
    transport_priority = bits.read_bit()
    info.pid = bits.read_bits 13
    # PID 0: Program Association Table
    # PID 1: Conditional Access Table
    # PID 2: Transport Stream Description Table
    # PID 3: IPMP Control Information Table
    # PID 4-15: reserved
    # PID 8191: reserved for null packets

    info.transport_scrambling_control = bits.read_bits 2
    info.adaptation_field_control = bits.read_bits 2
    info.continuity_counter = bits.read_bits 4

    # at here, already consumed 4 bytes. remaining is 184 bytes.
    remaining_bytes = TS_PACKET_SIZE - 4

    if info.adaptation_field_control in [2, 3]
      info.adaptation_field = api.read_adaptation_field bits
      remaining_bytes -= info.adaptation_field.adaptation_field_length + 1

    if info.adaptation_field_control in [1, 3]
      info.data = bits.read_bytes remaining_bytes

    # payload
    return info

  getNextPESPacket: ->
    bits = tsBits
    pesPacket = null
    if not isEOF
      loop
        try
          if not bits.has_more_data()
            isEOF = true
            break
          ts_packet = api.read_transport_packet bits
          if bufferingPESData[ts_packet.pid]?
            pid_pes = bufferingPESData[ts_packet.pid]
            if ts_packet.payload_unit_start_indicator
              if pid_pes.tmp.data.length > 0
                pid_pes.packets.push pid_pes.tmp
                pesPacket = {
                  pid: ts_packet.pid
                  packet: pid_pes.tmp
                  opts:
                    adaptation_field: ts_packet.adaptation_field
                }

              pid_pes.tmp =
                data: []
                adaptation_field: ts_packet.adaptation_field
            pid_pes.tmp.data.push ts_packet.data
            if pesPacket?
              return pesPacket
          else
            if not ts_packet.payload_unit_start_indicator
              logger.warn "mpegts: dropping residual PES packet for PID #{ts_packet.pid}"
            else
              bufferingPESData[ts_packet.pid] =
                packets: []
                tmp:
                  data: [ts_packet.data]
                  adaptation_field: ts_packet.adaptation_field
        catch e
          isEOF = true
          logger.error e.stack
          break
    for pid, pid_pes of bufferingPESData
      delete bufferingPESData[pid]
      if pid_pes.tmp.data.length > 0
        pid_pes.packets.push pid_pes.tmp
        pesPacket = {
          pid: parseInt(pid)
          packet: pid_pes.tmp
          opts:
            adaptation_field: pid_pes.adaptation_field
            is_last: true
        }
        pid_pes.tmp = null
        if pesPacket?
          return pesPacket
    return null

module.exports = api
