# H.264 parser
#
# H.264 spec is freely available at http://www.itu.int/rec/T-REC-H.264

fs = require 'fs'
Bits = require './bits'
logger = require './logger'

videoBuf = null
pps = {}
sps = {}

ASPECT_RATIO_IDC_EXTENDED_SAR = 255  # Extended_SAR

SUB_WIDTHS =
  # 'chroma_format_idc,separate_colour_plane_flag': [SubWidthC, SubHeightC]
  '1,0': [2, 2]
  '2,0': [2, 1]
  '3,0': [1, 1]

# rangeTabLPS
RANGE_TAB_LPS = [
  [ 128, 176, 208, 240 ]
  [ 128, 167, 197, 227 ]
  [ 128, 158, 187, 216 ]
  [ 123, 150, 178, 205 ]
  [ 116, 142, 169, 195 ]
  [ 111, 135, 160, 185 ]
  [ 105, 128, 152, 175 ]
  [ 100, 122, 144, 166 ]
  [ 95, 116, 137, 158 ]
  [ 90, 110, 130, 150 ]
  [ 85, 104, 123, 142 ]
  [ 81, 99, 117, 135 ]
  [ 77, 94, 111, 128 ]
  [ 73, 89, 105, 122 ]
  [ 69, 85, 100, 116 ]
  [ 66, 80, 95, 110 ]
  [ 62, 76, 90, 104 ]
  [ 59, 72, 86, 99 ]
  [ 56, 69, 81, 94 ]
  [ 53, 65, 77, 89 ]
  [ 51, 62, 73, 85 ]
  [ 48, 59, 69, 80 ]
  [ 46, 56, 66, 76 ]
  [ 43, 53, 63, 72 ]
  [ 41, 50, 59, 69 ]
  [ 39, 48, 56, 65 ]
  [ 37, 45, 54, 62 ]
  [ 35, 43, 51, 59 ]
  [ 33, 41, 48, 56 ]
  [ 32, 39, 46, 53 ]
  [ 30, 37, 43, 50 ]
  [ 29, 35, 41, 48 ]
  [ 27, 33, 39, 45 ]
  [ 26, 31, 37, 43 ]
  [ 24, 30, 35, 41 ]
  [ 23, 28, 33, 39 ]
  [ 22, 27, 32, 37 ]
  [ 21, 26, 30, 35 ]
  [ 20, 24, 29, 33 ]
  [ 19, 23, 27, 31 ]
  [ 18, 22, 26, 30 ]
  [ 17, 21, 25, 28 ]
  [ 16, 20, 23, 27 ]
  [ 15, 19, 22, 25 ]
  [ 14, 18, 21, 24 ]
  [ 14, 17, 20, 23 ]
  [ 13, 16, 19, 22 ]
  [ 12, 15, 18, 21 ]
  [ 12, 14, 17, 20 ]
  [ 11, 14, 16, 19 ]
  [ 11, 13, 15, 18 ]
  [ 10, 12, 15, 17 ]
  [ 10, 12, 14, 16 ]
  [ 9, 11, 13, 15 ]
  [ 9, 11, 12, 14 ]
  [ 8, 10, 12, 14 ]
  [ 8, 9, 11, 13 ]
  [ 7, 9, 11, 12 ]
  [ 7, 9, 10, 12 ]
  [ 7, 8, 10, 11 ]
  [ 6, 8, 9, 11 ]
  [ 6, 7, 9, 10 ]
  [ 6, 7, 8, 9 ]
  [ 2, 2, 2, 2 ]
]

# Name association to slice_type
SLICE_TYPES =
  0: 'P'
  1: 'B'
  2: 'I'
  3: 'SP'
  4: 'SI'
  5: 'P'
  6: 'B'
  7: 'I'
  8: 'SP'
  9: 'SI'

eventListeners = {}

lastPTS = null
lastDTS = null

dtsPackets = []

api =
  NAL_UNIT_TYPE_NON_IDR_PICTURE: 1 # inter frame
  NAL_UNIT_TYPE_IDR_PICTURE: 5     # key frame
  NAL_UNIT_TYPE_SEI: 6             # SEI (supplemental enhancement information)
  NAL_UNIT_TYPE_SPS: 7             # SPS (sequence parameter set)
  NAL_UNIT_TYPE_PPS: 8             # PPS (picture parameter set)
  NAL_UNIT_TYPE_ACCESS_UNIT_DELIMITER: 9  # access unit delimiter

  open: (file) ->
    videoBuf = fs.readFileSync file  # up to 1GB

  close: ->
    videoBuf = null

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

  end: ->
    @emit 'end'

  # Assumes the last NAL unit in this buffer is in complete form
  splitIntoNALUnits: (buffer) ->
    nalUnits = []
    loop
      startCodePos = Bits.searchBytesInArray buffer, [0x00, 0x00, 0x01], 0

      if startCodePos isnt -1
        nalUnit = buffer[0...startCodePos]
        buffer = buffer[startCodePos+3..]
      else
        nalUnit = buffer

      # Remove trailing_zero_8bits
      while nalUnit[nalUnit.length-1] is 0x00
        nalUnit = nalUnit[0...nalUnit.length-1]

      if nalUnit.length > 0
        nalUnits.push nalUnit

      if startCodePos is -1
        break
    return nalUnits

  feedPESPacket: (pesPacket) ->
    if videoBuf?
      videoBuf = Buffer.concat [videoBuf, pesPacket.pes.data]
    else
      videoBuf = pesPacket.pes.data

    pts = pesPacket.pes.PTS
    dts = pesPacket.pes.DTS

    nalUnits = []
    loop
      startCodePos = Bits.searchBytesInArray videoBuf, [0x00, 0x00, 0x01], 0

      if startCodePos is -1
        break
      nalUnit = videoBuf[0...startCodePos]
      videoBuf = videoBuf[startCodePos+3..]

      # Remove trailing_zero_8bits
      while nalUnit[nalUnit.length-1] is 0x00
        nalUnit = nalUnit[0...nalUnit.length-1]

      if nalUnit.length > 0
        nalUnitType = nalUnit[0] & 0x1f
        if nalUnitType is api.NAL_UNIT_TYPE_SPS
          api.readSPS nalUnit
        else if nalUnitType is api.NAL_UNIT_TYPE_PPS
          api.readPPS nalUnit
        else if nalUnitType is api.NAL_UNIT_TYPE_SEI
          api.readSEI nalUnit
        nalUnits.push nalUnit
        if (dtsPackets.length > 0) and (pts isnt lastPTS)
          dtsPackets.push nalUnit
          @emit 'dts_nal_units', lastPTS, lastDTS, dtsPackets
          dtsPackets = []
        else
          dtsPackets.push nalUnit
        lastPTS = pts
        lastDTS = dts

  feed: (data) ->
    if videoBuf?
      videoBuf = Buffer.concat [videoBuf, data]
    else
      videoBuf = data

    nalUnits = []
    loop
      startCodePos = Bits.searchBytesInArray videoBuf, [0x00, 0x00, 0x01], 0

      if startCodePos is -1
        break
      nalUnit = videoBuf[0...startCodePos]
      videoBuf = videoBuf[startCodePos+3..]

      # Remove trailing_zero_8bits
      while nalUnit[nalUnit.length-1] is 0x00
        nalUnit = nalUnit[0...nalUnit.length-1]

      if nalUnit.length > 0
        nalUnitType = nalUnit[0] & 0x1f
        if nalUnitType is api.NAL_UNIT_TYPE_SPS
          api.readSPS nalUnit
        else if nalUnitType is api.NAL_UNIT_TYPE_PPS
          api.readPPS nalUnit
        else if nalUnitType is api.NAL_UNIT_TYPE_SEI
          api.readSEI nalUnit
        nalUnits.push nalUnit
        @emit 'nal_unit', nalUnit
    if nalUnits.length > 0
      @emit 'nal_units', nalUnits

  hasMoreData: ->
    return videoBuf? and (videoBuf.length > 0)

  getNALUnitType: (nalUnit) ->
    return nalUnit[0] & 0x1f

  getSliceTypeString: (sliceType) ->
    return SLICE_TYPES[sliceType]

  isPictureNALUnitType: (nalUnitType) ->
    return nalUnitType in [
      api.NAL_UNIT_TYPE_NON_IDR_PICTURE,
      api.NAL_UNIT_TYPE_IDR_PICTURE
    ]

  getSPS: ->
    return sps

  getPPS: ->
    return pps

  readScalingList: (bits, scalingList, sizeOfScalingList, useDefaultScalingMatrixFlag) ->
    lastScale = 8
    nextScale = 8
    for j in [0...sizeOfScalingList]
      if nextScale isnt 0
        delta_scale = bits.read_se()
        nextScale = (lastScale + delta_scale + 256) % 256
        useDefaultScalingMatrixFlag = ((j is 0) and (nextScale is 0))
      scalingList[j] = if nextScale is 0 then lastScale else nextScale
      lastScale = scalingList[j]
    return

  read_user_data_unregistered: (bits, payloadSize) ->
    uuid_iso_iec_11578 = bits.read_bits 128
    for i in [16...payloadSize]
      user_data_payload_byte = bits.read_byte()

  read_reserved_sei_message: (bits, payloadSize) ->
    for i in [0...payloadSize]
      reserved_sei_message_payload_byte = bits.read_byte()

  read_sei_payload: (bits, payloadType, payloadSize) ->
    # ignore contents
    bits.read_bytes payloadSize

    # TODO
#    logger.debug "SEI: payloadType=#{payloadType} payloadSize=#{payloadSize}"
#    switch payloadType
#      when 0 then api.read_buffering_period payloadSize
#      when 1 then api.read_pic_timing payloadSize
#      when 2 then api.read_pan_scan_rect payloadSize
#      when 3 then api.read_filler_payload payloadSize
#      when 4 then api.read_user_data_registered_itu_t_t35 payloadSize
#      when 5 then api.read_user_data_unregistered bits, payloadSize
#      when 6 then api.read_recovery_point payloadSize
#      when 7 then api.read_dec_ref_pic_marking_repetition payloadSize
#      when 8 then api.read_spare_pic payloadSize
#      when 9 then api.read_scene_info payloadSize
#      when 10 then api.read_sub_seq_info payloadSize
#      ...
#      else api.read_reserved_sei_message bits, payloadSize

    bits.read_until_byte_aligned()

  read_sei_message: (bits) ->
    payloadType = 0
    while (byte = bits.read_byte()) is 0xff
      payloadType += 255
    last_payload_type_byte = byte
    payloadType += last_payload_type_byte
    payloadSize = 0
    while (byte = bits.read_byte()) is 0xff
      payloadSize += 255
    last_payload_size_byte = byte
    payloadSize += last_payload_size_byte
    api.read_sei_payload(bits, payloadType, payloadSize)

  readSEI: (nalUnit) ->
    nalUnit = api.removeEmulationPreventionByte nalUnit
    bits = new Bits nalUnit
    api.read_nal_header bits
    loop
      api.read_sei_message bits
      if not api.more_rbsp_data bits
        break
    return

  readPPS: (nalUnit) ->
    nalUnit = api.removeEmulationPreventionByte nalUnit
    bits = new Bits nalUnit
    api.read_nal_header bits
    pic_parameter_set_id = bits.read_ue()
    seq_parameter_set_id = bits.read_ue()
    pps.entropy_coding_mode_flag = bits.read_bit()
    pps.bottom_field_pic_order_in_frame_present_flag = bits.read_bit()
    pps.num_slice_groups_minus1 = bits.read_ue()
    if pps.num_slice_groups_minus1 > 0
      slice_group_map_type = bits.read_ue()
      if slice_group_map_type is 0
        for iGroup in [0..pps.num_slice_groups_minus1]
          run_length_minus1 = bits.read_ue()
      else if slice_group_map_type is 2
        for iGroup in [0...pps.num_slice_groups_minus1]
          top_left = bits.read_ue()
          bottom_right = bits.read_ue()
      else if slice_group_map_type in [3, 4, 5]
        slice_group_change_direction_flag = bits.read_bit()
        pps.slice_group_change_rate_minus1 = bits.read_ue()
      else if slice_group_map_type is 6
        pic_size_in_map_units_minus1 = bits.read_ue()
        for i in [0..pic_size_in_map_units_minus1]
          # Ceil( Log2( num_slice_groups_minus1 + 1 ) )
          numBits = Math.ceil(Math.log(pps.num_slice_groups_minus1 + 1) / Math.LN2)
          slice_group_id = bits.read_bits(numBits)
    pps.num_ref_idx_l0_default_active_minus1 = bits.read_ue()
    pps.num_ref_idx_l1_default_active_minus1 = bits.read_ue()
    pps.weighted_pred_flag = bits.read_bit()
    pps.weighted_bipred_idc = bits.read_bits 2
    pps.pic_init_qp_minus26 = bits.read_se()
    pic_init_qs_minus26 = bits.read_se()
    chroma_qp_index_offset = bits.read_se()
    pps.deblocking_filter_control_present_flag = bits.read_bit()
    constrained_intra_pred_flag = bits.read_bit()
    pps.redundant_pic_cnt_present_flag = bits.read_bit()
    if api.more_rbsp_data bits
      transform_8x8_mode_flag = bits.read_bit()
      pic_scaling_matrix_present_flag = bits.read_bit()
      if pic_scaling_matrix_present_flag is 1
        for i in [0...(6+(if sps.chroma_format_idc isnt 3 then 2 else 6)*transform_8x8_mode_flag)]
          pic_scaling_list_present_flag = bits.read_bit()
          if pic_scaling_list_present_flag
            if i < 6
              scalingList4x4 = []
              useDefaultScalingMatrix4x4Flag = []
              api.readScalingList(bits, scalingList4x4, 16,
                useDefaultScalingMatrix4x4Flag)
            else
              scalingList8x8 = []
              useDefaultScalingMatrix8x8Flag = []
              api.readScalingList(bits, scalingList8x8, 64,
                useDefaultScalingMatrix8x8Flag)
      second_chroma_qp_index_offset = bits.read_se()
    # rbsp_trailing_bits()
    return

  # Get width and height of video frame
  # @param sps (object): SPS object
  #
  # @return {
  #   width (number) : width in pixels
  #   height (number): height in pixels
  # }
  getFrameSize: (sps) ->
    if sps.chromaArrayType is 0
      cropUnitX = 1
      cropUnitY = 2 - sps.frame_mbs_only_flag
    else
      cropUnitX = sps.subWidthC
      cropUnitY = sps.subHeightC * (2 - sps.frame_mbs_only_flag)
    width = sps.picWidthInSamples -
      (cropUnitX * sps.frame_crop_right_offset + 1) -
      cropUnitX * sps.frame_crop_left_offset + 1
    height = (16 * sps.frameHeightInMbs) -
      (cropUnitY * sps.frame_crop_bottom_offset + 1) -
      cropUnitY * sps.frame_crop_top_offset + 1
    return {
      width: width
      height: height
    }

  getSubWidths: (sps) ->
    return SUB_WIDTHS[sps.chroma_format_idc + ',' +
      sps.separate_colour_plane_flag]

  readSPS: (nalUnit) ->
    sps = {}
    nalUnit = api.removeEmulationPreventionByte nalUnit
    bits = new Bits nalUnit
    api.read_nal_header bits
    sps.profile_idc = bits.read_byte()
    sps.constraint_set0_flag = bits.read_bit()
    sps.constraint_set1_flag = bits.read_bit()
    sps.constraint_set2_flag = bits.read_bit()
    sps.constraint_set3_flag = bits.read_bit()
    sps.constraint_set4_flag = bits.read_bit()
    sps.constraint_set5_flag = bits.read_bit()
    reserved_zero_2bits = bits.read_bits 2
    if reserved_zero_2bits isnt 0
      throw new Error "video error: reserved_zero_2bits must be 00: #{reserved_zero_2bits}"
    sps.level_idc = bits.read_byte()
    seq_parameter_set_id = bits.read_ue()

    if sps.profile_idc in [100, 110, 122, 244, 44, 83, 86, 118, 128]
      sps.chroma_format_idc = bits.read_ue()
      sps.chromaArrayType = sps.chroma_format_idc  # default value
      if sps.chroma_format_idc is 3
        sps.separate_colour_plane_flag = bits.read_bit()

        # Assign ChromaArrayType. See separate_colour_plane_flag
        # for the definition of ChromaArrayType.
        if sps.separate_colour_plane_flag is 1
          sps.chromaArrayType = 0
      else
        sps.separate_colour_plane_flag = 0
      bit_depth_luma_minus8 = bits.read_ue()
      bit_depth_chroma_minus8 = bits.read_ue()
      qpprime_y_zero_transform_bypass_flag = bits.read_bit()
      seq_scaling_matrix_present_flag = bits.read_bit()
      if seq_scaling_matrix_present_flag
        for i in [0...(if sps.chroma_format_idc isnt 3 then 8 else 12)]
          seq_scaling_list_present_flag = bits.read_bit()
          if seq_scaling_list_present_flag
            if i < 6
              scalingList4x4 = []
              useDefaultScalingMatrix4x4Flag = []
              api.readScalingList(bits, scalingList4x4, 16,
                useDefaultScalingMatrix4x4Flag)
            else
              scalingList8x8 = []
              useDefaultScalingMatrix8x8Flag = []
              api.readScalingList(bits, scalingList8x8, 64,
                useDefaultScalingMatrix8x8Flag)
    else
      sps.chromaArrayType = sps.chroma_format_idc = 1  # 4:2:0 chroma format
      sps.separate_colour_plane_flag = 0
    subWidths = api.getSubWidths sps

    if subWidths?
      sps.subWidthC = subWidths[0]
      sps.subHeightC = subWidths[1]
    sps.log2_max_frame_num_minus4 = bits.read_ue()
    sps.pic_order_cnt_type = bits.read_ue()
    if sps.pic_order_cnt_type is 0
      sps.log2_max_pic_order_cnt_lsb_minus4 = bits.read_ue()
    else if sps.pic_order_cnt_type is 1
      delta_pic_order_always_zero_flag = bits.read_bit()
      offset_for_non_ref_pic = bits.read_se()
      offset_for_top_to_bottom_field = bits.read_se()
      num_ref_frames_in_pic_order_cnt_cycle = bits.read_ue()
      for i in [0...num_ref_frames_in_pic_order_cnt_cycle]
        offset_for_ref_frame = bits.read_se()
    sps.max_num_ref_frames = bits.read_ue()
    gaps_in_frame_num_value_allowed_flag = bits.read_bit()
    sps.pic_width_in_mbs_minus1 = bits.read_ue()
    sps.pic_height_in_map_units_minus1 = bits.read_ue()
    sps.picWidthInMbs = sps.pic_width_in_mbs_minus1 + 1
    sps.picWidthInSamples = sps.picWidthInMbs * 16
    sps.picHeightInMapUnits = sps.pic_height_in_map_units_minus1 + 1
    sps.picSizeInMapUnits = sps.picWidthInMbs * sps.picHeightInMapUnits
    sps.frame_mbs_only_flag = bits.read_bit()
    sps.frameHeightInMbs = (2 - sps.frame_mbs_only_flag) * sps.picHeightInMapUnits
    if not sps.frame_mbs_only_flag
      sps.mb_adaptive_frame_field_flag = bits.read_bit()
    direct_8x8_inference_flag = bits.read_bit()
    frame_cropping_flag = bits.read_bit()
    if frame_cropping_flag
      sps.frame_crop_left_offset   = bits.read_ue()
      sps.frame_crop_right_offset  = bits.read_ue()
      sps.frame_crop_top_offset    = bits.read_ue()
      sps.frame_crop_bottom_offset = bits.read_ue()
    else
      sps.frame_crop_left_offset   = 0
      sps.frame_crop_right_offset  = 0
      sps.frame_crop_top_offset    = 0
      sps.frame_crop_bottom_offset = 0
    vui_parameters_present_flag = bits.read_bit()
    if vui_parameters_present_flag
      api.read_vui_parameters bits

    # rbsp_trailing_bits
    rbsp_stop_one_bit = bits.read_bit()
    if rbsp_stop_one_bit isnt 1
      logger.warn "warn: malformed SPS data: rbsp_stop_one_bit must be 1"

    zero_bits_sum = bits.read_until_byte_aligned()
    if zero_bits_sum isnt 0
      logger.warn "warn: malformed SPS data: rbsp_alignment_zero_bit must be all zeroes"

    if bits.get_remaining_bits() isnt 0
      logger.warn "warn: malformed SPS length"

    return sps

  read_slice_data: (bits, opts) ->
    if pps.entropy_coding_mode_flag
      bits.read_until_byte_aligned()  # cabac_alignment_one_bit
    currMbAddr = opts.sliceHeader.first_mb_in_slice * (1 + opts.sliceHeader.mbaffFrameFlag)
    moreDataFlag = 1
    prevMbSkipped = 0
    sliceTypeString = api.getSliceTypeString opts.sliceHeader.slice_type
#    loop
#      if sliceTypeString not in ['I', 'SI']
#        if not pps.entropy_coding_mode_flag
#          mb_skip_run = bits.read_ue()
#          prevMbSkipped = mb_skip_run > 0
#          for i in [0...mb_skip_run]
#            currMbAddr = nextMbAddress(currMbAddr)
#          if mb_skip_run > 0
#            moreDataFlag = api.more_rbsp_data bits
#        else
#          sliceQPy = 26 + pps.pic_init_qp_minus26 + opts.sliceHeader.slice_qp_delta
#          mb_skip_flag = api.read_ae bits
#            sliceQPy: sliceQPy

  read_ref_pic_list_mvc_modification: (opts) ->
    throw new Error "Not implemented"

  read_ref_pic_list_modification: (bits, opts) ->
    sliceHeader = opts.sliceHeader

    if sliceHeader.slice_type % 5 not in [2, 4]
      ref_pic_list_modification_flag_l0 = bits.read_bit()
      if ref_pic_list_modification_flag_l0
        if sliceHeader.num_ref_idx_active_override_flag
          l0 = sliceHeader.num_ref_idx_l0_active_minus1 + 1
        else
          l0 = pps.num_ref_idx_l0_default_active_minus1 + 1
        loop
          modification_of_pic_nums_idc = bits.read_ue()
          if modification_of_pic_nums_idc in [0, 1]
            abs_diff_pic_num_minus1 = bits.read_ue()
          else if modification_of_pic_nums_idc is 2
            long_term_pic_num = bits.read_ue()
          if modification_of_pic_nums_idc is 3
            break
    if sliceHeader.slice_type % 5 is 1
      ref_pic_list_modification_flag_l1 = bits.read_bit()
      if ref_pic_list_modification_flag_l1
        loop
          modification_of_pic_nums_idc = bits.read_ue()
          if modification_of_pic_nums_idc in [0, 1]
            abs_diff_pic_num_minus1 = bits.read_ue()
          else if modification_of_pic_nums_idc is 2
            long_term_pic_num = bits.read_ue()
          if modification_of_pic_nums_idc is 3
            break
    return

  read_pred_weight_table: (bits, opts) ->
    sliceHeader = opts.sliceHeader

    luma_log2_weight_denom = bits.read_ue()
    if not sps.chromaArrayType?
      throw new Error "ChromaArrayType isn't set"
    if sps.chromaArrayType isnt 0
      chroma_log2_weight_denom = bits.read_ue()
    luma_weight_10 = []
    luma_offset_10 = []
    chroma_weight_10 = []
    chroma_offset_10 = []
    for i in [0..sliceHeader.num_ref_idx_l0_active_minus1]
      luma_weight_10_flag = bits.read_bit()
      if luma_weight_10_flag
        luma_weight_10[i] = bits.read_se()
        luma_offset_10[i] = bits.read_se()
      if sps.chromaArrayType isnt 0
        chroma_weight_10_flag = bits.read_bit()
        if chroma_weight_10_flag
          chroma_weight_10[i] = []
          chroma_offset_10[i] = []
          for j in [0...2]
            chroma_weight_10[i][j] = bits.read_se()
            chroma_offset_10[i][j] = bits.read_se()
    if sliceHeader.slice_type % 5 is 1
      luma_weight_11 = []
      luma_offset_11 = []
      chroma_weight_11 = []
      chroma_offset_11 = []
      for i in [0..sliceHeader.num_ref_idx_l1_active_minus1]
        luma_weight_11_flag = bits.read_bit()
        if luma_weight_11_flag
          luma_weight_11[i] = bits.read_se()
          luma_offset_11[i] = bits.read_se()
        if sps.chromaArrayType isnt 0
          chroma_weight_11_flag = bits.read_bit()
          if chroma_weight_11_flag
            chroma_weight_11[i] = []
            chroma_offset_11[i] = []
            for j in [0...2]
              chroma_weight_11[i][j] = bits.read_se()
              chroma_offset_11[i][j] = bits.read_se()

  read_dec_ref_pic_marking: (bits, opts) ->
    sliceHeader = opts.sliceHeader

    if sliceHeader.idrPicFlag
      no_output_of_prior_pics_flag = bits.read_bit()
      long_term_reference_flag = bits.read_bit()
    else
      adaptive_ref_pic_marking_mode_flag = bits.read_bit()
      if adaptive_ref_pic_marking_mode_flag
        loop
          memory_management_control_operation = bits.read_ue()
          if memory_management_control_operation in [1, 3]
            difference_of_pic_nums_minus1 = bits.read_ue()
          if memory_management_control_operation is 2
            long_term_pic_num = bits.read_ue()
          if memory_management_control_operation in [3, 6]
            long_term_frame_idx = bits.read_ue()
          if memory_management_control_operation is 4
            max_long_term_frame_idx_plus1 = bits.read_ue()
          if memory_management_control_operation is 0
            break

  read_slice_header: (bits, opts) ->
    sliceHeader = opts.sliceHeader = {}

    if opts.nalHeader.nal_unit_type is api.NAL_UNIT_TYPE_IDR_PICTURE
      sliceHeader.idrPicFlag = 1
    else
      sliceHeader.idrPicFlag = 0

    sliceHeader.first_mb_in_slice = bits.read_ue()
    sliceHeader.slice_type = bits.read_ue()
    sliceHeader.pic_parameter_set_id = bits.read_ue()
    if sps.separate_colour_plane_flag is 1
      colour_plane_id = bits.read_bits 2
    sliceHeader.frame_num = bits.read_bits(sps.log2_max_frame_num_minus4 + 4)
    if not sps.frame_mbs_only_flag
      sliceHeader.field_pic_flag = bits.read_bit()
      if sliceHeader.field_pic_flag
        sliceHeader.bottom_field_flag = bits.read_bit()

    if sps.mb_adaptive_frame_field_flag and not sliceHeader.field_pic_flag
      sliceHeader.mbaffFrameFlag = 1
    else
      sliceHeader.mbaffFrameFlag = 0

    if sliceHeader.idrPicFlag
      sliceHeader.idr_pic_id = bits.read_ue()
    if sps.pic_order_cnt_type is 0
      sliceHeader.pic_order_cnt_lsb = bits.read_bits(sps.log2_max_pic_order_cnt_lsb_minus4 + 4)
      if pps.bottom_field_pic_order_in_frame_present_flag and not sliceHeader.field_pic_flag
        sliceHeader.delta_pic_order_cnt_bottom = bits.read_se()
    if (sps.pic_order_cnt_type is 1) and (not delta_pic_order_always_zero_flag)
      sliceHeader.delta_pic_order_cnt_0 = bits.read_se()
      if pps.bottom_field_pic_order_in_frame_present_flag and not sliceHeader.field_pic_flag
        sliceHeader.delta_pic_order_cnt_1 = bits.read_se()
    if pps.redundant_pic_cnt_present_flag
      redundant_pic_cnt = bits.read_ue()
    sliceTypeString = api.getSliceTypeString sliceHeader.slice_type
    if sliceTypeString is 'B'
      direct_spatial_mv_pred_flag = bits.read_bit()
    if sliceTypeString in ['P', 'SP', 'B']
      sliceHeader.num_ref_idx_active_override_flag = bits.read_bit()
      if sliceHeader.num_ref_idx_active_override_flag
        sliceHeader.num_ref_idx_l0_active_minus1 = bits.read_ue()
        if sliceTypeString is 'B'
          sliceHeader.num_ref_idx_l1_active_minus1 = bits.read_ue()
    if opts.nalHeader.nal_unit_type is 20
      api.read_ref_pic_list_mvc_modification opts
    else
      api.read_ref_pic_list_modification bits, opts
    if (pps.weighted_pred_flag and sliceTypeString in ['P', 'SP']) or
    (pps.weighted_bipred_idc is 1 and sliceTypeString is 'B')
      api.read_pred_weight_table bits, opts
    if opts.nalHeader.nal_ref_idc isnt 0
      api.read_dec_ref_pic_marking bits, opts
    if pps.entropy_coding_mode_flag and (sliceTypeString not in ['I', 'SI'])
      cabac_init_idc = bits.read_ue()
    sliceHeader.slice_qp_delta = bits.read_se()
    if sliceTypeString in ['SP', 'SI']
      if sliceTypeString is 'SP'
        sliceHeader.sp_for_switch_flag = bits.read_bit()
      slice_qs_delta = bits.read_se()
    if pps.deblocking_filter_control_present_flag
      disable_deblocking_filter_idc = bits.read_ue()
      if disable_deblocking_filter_idc isnt 1
        slice_alpha_c0_offset_div2 = bits.read_se()
        slice_beta_offset_div2 = bits.read_se()
    if (pps.num_slice_groups_minus1 > 0) and (3 <= slice_group_map_type <= 5)
      # Ceil( Log2( PicSizeInMapUnits + SliceGroupChangeRate + 1 ) )
      numBits = Math.ceil(Math.log(sps.picSizeInMapUnits +
        pps.slice_group_change_rate_minus1 + 1) / Math.LN2)
      sliceHeader.slice_group_change_cycle = bits.read_bits(numBits)

  _isSamePicture: (nalData1, nalData2) ->
    for elem in [
      'pic_parameter_set_id'
      'frame_num'
      'field_pic_flag'
      'bottom_field_flag'
      'idr_pic_id'
      'pic_order_cnt_lsb'
      'delta_pic_order_cnt_bottom'
      'delta_pic_order_cnt_0'
      'delta_pic_order_cnt_1'
      'sp_for_switch_flag'
      'slice_group_change_cycle'
    ]
      if nalData1.sliceHeader[elem] isnt nalData2.sliceHeader[elem]
        # different picture
        return false
    # same picture
    return true

  # Returns whether nalUnit1 and nalUnit2 share the same coded picture
  #
  # @return  boolean  true if the NAL units have the same picture.
  isSamePicture: (nalUnit1, nalUnit2) ->
    nalData1 = api.parseNALUnit nalUnit1
    nalData2 = api.parseNALUnit nalUnit2
    api._isSamePicture nalData1, nalData2

  parseNALUnit: (nalUnit) ->
    data = {}
    nalUnit = api.removeEmulationPreventionByte nalUnit
    bits = new Bits nalUnit
    data.nalHeader = api.read_nal_header bits
    if data.nalHeader.nal_unit_type in [
      api.NAL_UNIT_TYPE_NON_IDR_PICTURE
      api.NAL_UNIT_TYPE_IDR_PICTURE
    ]
      api.read_slice_header bits, data
    return data

  # Removes all emulation prevention bytes (0x03 in 0x000003) from nalUnit and
  # returns a new Buffer. If no emulation prevention bytes found in nalUnit,
  # the returned value is the same Buffer instance as the given nalUnit.
  removeEmulationPreventionByte: (nalUnit) ->
    searchPos = 0
    removeBytePositions = []
    loop
      emulPos = Bits.searchBytesInArray nalUnit, [0x00, 0x00, 0x03], searchPos
      if emulPos is -1
        break
      removeBytePositions.push emulPos + 2
      searchPos = emulPos + 3
    if removeBytePositions.length > 0
      newBuf = new Buffer nalUnit.length - removeBytePositions.length
      currentSrcPos = 0
      for pos, i in removeBytePositions
        # srcBuf.copy(destBuf, destStart, srcStart, srcEnd)
        nalUnit.copy newBuf, currentSrcPos - i, currentSrcPos, pos
        currentSrcPos = pos + 1
      if currentSrcPos < nalUnit.length
        nalUnit.copy newBuf, currentSrcPos - removeBytePositions.length,
          currentSrcPos, nalUnit.length
      nalUnit = newBuf
    return nalUnit

  # opts:
  #   retrieveOnly (boolean): if true, videoBuf remains intact
  getNextNALUnit: ->
    if not api.hasMoreData()
      return null

    # Search for H.264 start code prefix.
    #
    # H.264 NAL unit is preceded by a byte-aligned
    # "start code prefix" (0x000001). H.264 has "emulation
    # prevention byte" (0x03) which is used to prevent a
    # occurrence of 0x000001 in a NAL unit. Therefore a
    # byte-aligned 0x000001 is always a start code prefix.
    startCodePos = Bits.searchBytesInArray videoBuf, [0x00, 0x00, 0x01], 0
    if startCodePos is -1  # last NAL unit
      nalUnit = videoBuf
      videoBuf = []
      return nalUnit
    nalUnit = videoBuf[0...startCodePos]

    # Truncate video buffer
    videoBuf = videoBuf[startCodePos+3..]

    # Remove trailing_zero_8bits
    while nalUnit[nalUnit.length-1] is 0x00
      nalUnit = nalUnit[0...nalUnit.length-1]

    if nalUnit.length > 0
      nalUnitType = nalUnit[0] & 0x1f
      if nalUnitType is api.NAL_UNIT_TYPE_SPS
        api.readSPS nalUnit
      else if nalUnitType is api.NAL_UNIT_TYPE_PPS
        api.readPPS nalUnit
      else if nalUnitType is api.NAL_UNIT_TYPE_SEI
        api.readSEI nalUnit
      return nalUnit
    else
      return api.getNextNALUnit()

  clip3: (x, y, z) ->
    if z < x
      return x
    if z > y
      return y
    return z

  # 9.3.3.2.3
  decodeBypass: (bits, vars) ->
    vars.codIOffset <<= 1
    vars.codIOffset |= bits.read_bit()
    if vars.codIOffset >= vars.codIRange
      vars.binVal = 1
      vars.codIOffset -= vars.codIRange
    else
      vars.binVal = 0

  deriveCtxIdx: (input) ->
    # input
    binIdx = input.binIdx
    maxBinIdxCtx = input.maxBinIdxCtx
    ctxIdxOffset = input.ctxIdxOffset

    # TODO
    ctxIdxInc = null

    return {
      ctxIdx: 0
    }

  # 9.3.3.2.2
  renormD: (bits, vars) ->
    while vars.codIRange < 256
      vars.codIRange <<= 1
      vars.codIOffset <<= 1  # TODO: correct?
      vars.codIOffset |= bits.read_bit()

  # 9.3.3.2.4
  decodeTerminate: (bits, vars) ->
    vars.codIRange -= 2
    if vars.codIOffset >= vars.codIRange
      vars.binVal = 1
    else
      vars.binVal = 0
      api.renormD bits

  # 9.3.3.2.1
  decodeDecision: (vars) ->
    qCodIRangeIdx = (vars.codIRange >> 6) & 3
    codIRangeLPS = rangeTabLPS[vars.pStateIdx][qCodIRangeIdx]
    vars.codIRange -= codIRangeLPS
    if vars.codIOffset >= vars.codIRange
      vars.binVal = 1 - vars.valMPS
      vars.codIOffset -= vars.codIRange
      vars.codIRange = codIRangeLPS
    else
      vars.binVal = vars.valMPS

    # 9.3.3.2.1.1
    if vars.binVal is vars.valMPS
      vars.pStateIdx = transIdxMPS(vars.pStateIdx)
    else
      if vars.pStateIdx is 0
        vars.valMPS = 1 - vars.valMPS
      vars.pStateIdx = transIdxLPS(vars.pStateIdx)

    api.renormD vars

  read_ae: (bits, opts) ->
    # TODO
    throw new Error "Not implemented"

#    bypassFlag = opts.bypassFlag
#    ctxIdx = opts.ctxIdx
#
#    # 9.3.1.1 initialization
#    preCtxState = api.clip3(1, 126,
#      ((m * api.clip3(0, 51, opts.sliceQPy)) >> 4) + n)
#    if preCtxState <= 63
#      pStateIdx = 63 - preCtxState
#      valMPS = 0
#    else
#      pStateIdx = preCtxState - 64
#      valMPS = 1
#
#    # 9.3.1.2
#    vars =
#      codIRange: 510
#      codIOffset: bits.read_bits 9
#      pStateIdx: pStateIdx
#      valMPS: valMPS
#    if vars.codIOffset in [510, 511]
#      throw new Error "Illegal codIOffset: #{vars.codIOffset}"
#
#    if bypassFlag is 1
#      decodeBypass vars
#    else if bypassFlag is 0 and ctxIdx is 276
#      decodeTerminate bits
#    else
#      decodeDecision()

  read_nal_unit_header_svc_extension: ->
    # TODO
    throw new Error "Not implemented"

  read_nal_unit_header_mvc_extension: ->
    # TODO
    throw new Error "Not implemented"

  read_nal_header: (bits) ->
    nalHeader = {}
    forbidden_zero_bit = bits.read_bit()
    nalHeader.nal_ref_idc = bits.read_bits 2
    nalHeader.nal_unit_type = bits.read_bits 5
    if nalHeader.nal_unit_type in [14, 20]
      svc_extension_flag = bits.read_bit()
      if svc_extension_flag
        api.read_nal_unit_header_svc_extension()
      else
        api.read_nal_unit_header_mvc_extension()
    return nalHeader

  read_hrd_parameters: (bits) ->
    cpb_cnt_minus1 = bits.read_ue()
    bit_rate_scale = bits.read_bits 4
    cpb_size_scale = bits.read_bits 4
    bit_rate_value_minus1 = []
    cpb_size_value_minus1 = []
    cbr_flag = []
    for schedSelIdx in [0..cpb_cnt_minus1]
      bit_rate_value_minus1[schedSelIdx] = bits.read_ue()
      cpb_size_value_minus1[schedSelIdx] = bits.read_ue()
      cbr_flag[schedSelIdx] = bits.read_bit()
    initial_cpb_removal_delay_length_minus1 = bits.read_bits 5
    cpb_removal_delay_length_minus1 = bits.read_bits 5
    dpb_output_delay_length_minus1 = bits.read_bits 5
    time_offset_length = bits.read_bits 5

  read_vui_parameters: (bits) ->
    vui = {}
    vui.aspect_ratio_info_present_flag = bits.read_bit()
    if vui.aspect_ratio_info_present_flag
      vui.aspect_ratio_idc = bits.read_bits 8
      if vui.aspect_ratio_idc is ASPECT_RATIO_IDC_EXTENDED_SAR
        vui.sar_width = bits.read_bits 16
        vui.sar_height = bits.read_bits 16
    vui.overscan_info_present_flag = bits.read_bit()
    if vui.overscan_info_present_flag
      vui.overscan_appropriate_flag = bits.read_bit()
    vui.video_signal_type_present_flag = bits.read_bit()
    if vui.video_signal_type_present_flag
      vui.video_format = bits.read_bits 3
      vui.video_full_range_flag = bits.read_bit()
      vui.colour_description_present_flag = bits.read_bit()
      if vui.colour_description_present_flag
        vui.colour_primaries = bits.read_bits 8
        vui.transfer_characteristics = bits.read_bits 8
        vui.matrix_coefficients = bits.read_bits 8
    vui.chroma_loc_info_present_flag = bits.read_bit()
    if vui.chroma_loc_info_present_flag is 1
      vui.chroma_sample_loc_type_top_field = bits.read_ue()
      vui.chroma_sample_loc_type_bottom_field = bits.read_ue()
    vui.timing_info_present_flag = bits.read_bit()
    if vui.timing_info_present_flag
      vui.num_units_in_tick = bits.read_bits 32
      vui.time_scale = bits.read_bits 32
      vui.fixed_frame_rate_flag = bits.read_bit()
    vui.nal_hrd_parameters_present_flag = bits.read_bit()
    if vui.nal_hrd_parameters_present_flag
      api.read_hrd_parameters bits
    vui.vcl_hrd_parameters_present_flag = bits.read_bit()
    if vui.vcl_hrd_parameters_present_flag
      api.read_hrd_parameters bits
    if vui.nal_hrd_parameters_present_flag or vui.vcl_hrd_parameters_present_flag
      vui.low_delay_hrd_flag = bits.read_bit()
    vui.pic_struct_present_flag = bits.read_bit()
    vui.bitstream_restriction_flag = bits.read_bit()
    if vui.bitstream_restriction_flag
      vui.motion_vectors_over_pic_boundaries_flag = bits.read_bit()
      vui.max_bytes_per_pic_denom = bits.read_ue()
      vui.max_bits_per_mb_denom = bits.read_ue()
      vui.log2_max_mv_length_horizontal = bits.read_ue()
      vui.log2_max_mv_length_vertical = bits.read_ue()
      vui.max_num_reorder_frames = bits.read_ue()
      vui.max_dec_frame_buffering = bits.read_ue()

  # returns an object {
  #   byte: byte index (starts from 0)
  #   bit : bit index (starts from 0)
  # }. If it is not found, returns null.
  search_rbsp_stop_one_bit: (bits) ->
    return bits.lastIndexOfBit 1

  more_rbsp_data: (bits) ->
    remaining_bits = bits.get_remaining_bits()
    if remaining_bits is 0
      return false  # no more data
    stop_bit_pos = api.search_rbsp_stop_one_bit bits
    if not stop_bit_pos?
      throw new Error "stop_one_bit is not found"
    currPos = bits.current_position()
    if (stop_bit_pos.byte > currPos.byte) or (stop_bit_pos.bit > currPos.bit)
      return true
    else
      return false

  concatWithStartCodePrefix: (bufs) ->
    nalUnitsWithStartCodePrefix = []
    startCodePrefix = new Buffer [0x00, 0x00, 0x00, 0x01]
    totalLen = 0
    for buf in bufs
      nalUnitsWithStartCodePrefix.push startCodePrefix
      nalUnitsWithStartCodePrefix.push buf
      totalLen += 4 + buf.length
    return Buffer.concat nalUnitsWithStartCodePrefix, totalLen

  # ISO 14496-15 5.2.4.1.1
  readAVCDecoderConfigurationRecord: (bits) ->
    info = {}
    info.configurationVersion = bits.read_byte()
    if info.configurationVersion isnt 1
      throw new Error "configurationVersion is not 1: #{info.configurationVersion}"

    # SPS[1..3]
    info.avcProfileIndication = bits.read_byte()
    info.profile_compatibility = bits.read_byte()
    info.avcLevelIndication = bits.read_byte()

    bits.skip_bits 6  # reserved
    info.lengthSizeMinusOne = bits.read_bits 2
    info.nalUnitLengthSize = info.lengthSizeMinusOne + 1
    bits.skip_bits 3  # reserved
    info.numOfSPS = bits.read_bits 5
    info.sps = []
    for i in [0...info.numOfSPS]
      spsLen = bits.read_bits 16
      info.sps.push bits.read_bytes spsLen
    info.numOfPPS = bits.read_byte()
    info.pps = []
    for i in [0...info.numOfPPS]
      ppsLen = bits.read_bits 16
      info.pps.push bits.read_bytes ppsLen
    return info

  # Parse sprop-parameter-sets which is
  # appeared in RTP payload (RFC 6184)
  parseSpropParameterSets: (str) ->
    nalUnits = []
    for base64String in str.split ','
      nalUnits.push new Buffer base64String, 'base64'
    return nalUnits

module.exports = api
