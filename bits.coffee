# Utility functions for buffer operation

buf = null
byte_index = 0
bit_index = 0

stash_buf = []
stash_byte_index = []
stash_bit_index = []

c_buf = null
c_byte_index = 0
c_bit_index = 0

api =
  create_buf: ->
    c_buf = []
    c_byte_index = 0
    c_bit_index = 0

  add_bit: (value) ->
    api.add_bits 1, value

  # @param  numBits (int) number of bits to fill with 1
  fill_bits_with_1: (numBits) ->
    if numBits > 32
      throw new Error "numBits must be <= 32"
    value = Math.pow(2, numBits) - 1
    api.add_bits numBits, value

  # value is up to 32-bit unsigned integer
  add_bits: (numBits, value) ->
    if value > 0xffffffff
      throw new Error "value must be <= 0xffffffff (uint32)"
    if value < 0
      throw new Error "value must be >= 0 (uint32)"
    remaining_len = numBits
    while remaining_len > 0
      if not c_buf[c_byte_index]?  # not initialized
        c_buf[c_byte_index] = 0x00  # initialize
      available_len = 8 - c_bit_index
      if remaining_len <= available_len  # fits into current byte
        c_buf[c_byte_index] |= value << (available_len - remaining_len)
        c_bit_index += remaining_len
        remaining_len = 0
        if c_bit_index is 8
          c_byte_index++
          c_bit_index = 0
      else
        this_value = (value >>> (remaining_len - available_len)) & 0xff
        c_buf[c_byte_index] |= this_value
        remaining_len -= available_len
        c_byte_index++
        c_bit_index = 0

  # @return array
  get_created_buf: ->
    return c_buf

  current_position: ->
    return {
      byte: byte_index
      bit : bit_index
    }

  print_position: ->
    remaining_bits = api.get_remaining_bits()
    console.log "byteIndex=#{byte_index+1} bitIndex=#{bit_index} remaining_bits=#{remaining_bits}"

  peak_bytes: ->
    console.log buf[byte_index..]
    console.log "bit_index=#{bit_index} (byte_index=#{byte_index})"

  skip_bits: (len) ->
    bit_index += len
    while bit_index >= 8
      byte_index++
      bit_index -= 8
    return

  skip_bytes: (len) ->
    byte_index += len

  # Returns the number of skipped bytes
  skip_bytes_equal_to: (value) ->
    count = 0
    loop
      byte = api.read_byte()
      if byte isnt value
        api.push_back_byte()
        return count
      count++

  read_uint32: ->
    return api.read_byte() * Math.pow(256, 3) +
           (api.read_byte() << 16) +
           (api.read_byte() << 8) +
           api.read_byte()

  # Read a signed number represented by two's complement.
  # bits argument is the length of the signed number including
  # the sign bit.
  read_int: (bits) ->
    if bits < 0
      throw new Error "read_int: bits argument must be positive: #{bits}"
    if bits is 1
      return api.read_bit()
    sign_bit = api.read_bit()
    value = api.read_bits bits - 1
    if sign_bit is 1  # negative number
      return -Math.pow(2, bits - 1) + value
    else  # positive number
      return value

  # unsigned integer Exp-Golomb-coded syntax element
  # see clause 9.1
  read_ue: ->
    return api.read_exp_golomb()

  # signed integer Exp-Golomb-coded syntax element
  read_se: ->
    value = api.read_exp_golomb()
    return Math.pow(-1, value + 1) * Math.ceil(value / 2)

  read_exp_golomb: ->
    leadingZeroBits = -1
    b = 0
    while b is 0
      b = api.read_bit()
      leadingZeroBits++
    return Math.pow(2, leadingZeroBits) - 1 + api.read_bits(leadingZeroBits)

  # Return an instance of Buffer
  read_bytes: (len, suppress_boundary_warning=0) ->
    if bit_index isnt 0
      throw new Error "read_bytes: bit_index must be 0"

    if (not suppress_boundary_warning) and (byte_index + len > buf.length)
      console.log "[warn] read_bytes exceeds boundary: #{byte_index+len} > #{buf.length}"

    range = buf[byte_index...byte_index+len]
    byte_index += len
    return range

  read_byte: ->
    if bit_index is 0
      if byte_index >= buf.length
        throw new Error "read_byte error: no more data"
      value = buf[byte_index++]
    else
      value = api.read_bits 8
    return value

  read_bits: (len) ->
    if len is 0
      return 0

    bit_buf = ''
    for i in [0...len]
      bit_buf += api.read_bit().toString()
    return parseInt bit_buf, 2

  read_bit: ->
    if byte_index >= buf.length
      throw new Error "read_bit error: no more data"
    value = api.bit bit_index++, buf[byte_index]
    if bit_index is 8
      byte_index++
      bit_index = 0
#      if byte_index >= buf.length
#        console.log "All bytes read"
    return value

  push_back_byte: ->
    api.push_back_bytes 1

  push_back_bytes: (len) ->
    api.push_back_bits len * 8

  push_back_bits: (len) ->
    while len-- > 0
      bit_index--
      if bit_index is -1
        bit_index = 7
        byte_index--
    return

  bit: (index, byte) ->
    result = null
    if index instanceof Array
      result = []
      for idx in result
        result.push (byte >> (7 - idx)) & 0x01
    else
      result = (byte >> (7 - index)) & 0x01
    return result

  push_stash: ->
    stash_buf.push buf
    stash_byte_index.push byte_index
    stash_bit_index.push bit_index

  pop_stash: ->
    buf = stash_buf.shift()
    byte_index = stash_byte_index.shift()
    bit_index = stash_bit_index.shift()

  set_data: (bytes) ->
    buf = bytes
    byte_index = 0
    bit_index = 0

  has_more_data: ->
    return api.get_remaining_bits() > 0

  get_remaining_bits: ->
    total_bits = buf.length * 8
    total_read_bits = byte_index * 8 + bit_index
    return total_bits - total_read_bits

  remaining_buffer: ->
    return buf[byte_index..]

  is_byte_aligned: ->
    return bit_index is 0

  read_until_byte_aligned: ->
    sum = 0
    while bit_index isnt 0
      sum += api.read_bit()
    return sum

  # @param bitVal (number)  0 or 1
  #
  # @return object or null  If rbsp_stop_one_bit is found,
  # returns an object {
  #   byte: (number) byte index (starts from 0)
  #   bit : (number) bit index (starts from 0)
  # }. If it is not found, returns null.
  lastIndexOfBit: (bitVal) ->
    for i in [buf.length-1..byte_index]
      byte = buf[i]
      if (bitVal is 1 and byte isnt 0x00) or (bitVal is 0 and byte isnt 0xff)
        # this byte contains the target bit
        for col in [0..7]
          if ((byte >> col) & 0x01) is bitVal
            return byte: i, bit: 7 - col
          if (i is byte_index) and (7 - col is bit_index)
            return null
    return null  # not found

  searchBytesInArray: (haystack, needle, from_pos=0) ->
    if from_pos >= haystack.length
      return -1

    needle_idx = 0
    haystack_idx = from_pos
    haystack_len = haystack.length
    loop
      if haystack[haystack_idx] is needle[needle_idx]
        needle_idx++
        if needle_idx is needle.length
          return haystack_idx - needle.length + 1
      else
        if needle_idx > 0
          haystack_idx -= needle_idx
          needle_idx = 0
      haystack_idx++
      if haystack_idx is haystack_len
        return -1

  searchBitsInArray: (haystack, needle, fromPos=0) ->
    if fromPos >= haystack.length
      return -1

    needleIdx = 0
    haystackIdx = fromPos
    haystackLen = haystack.length
    loop
      if (haystack[haystackIdx] & needle[needleIdx]) is needle[needleIdx]
        needleIdx++
        if needleIdx is needle.length
          return haystackIdx - needle.length + 1
      else
        if needleIdx > 0
          haystackIdx -= needleIdx
          needleIdx = 0
      haystackIdx++
      if haystackIdx is haystackLen
        return -1

  get_current_byte: ->
    return api.get_byte_at 0

  get_byte_at: (byteOffset) ->
    if bit_index is 0
      return buf[byte_index + byteOffset]
    else
      api.parse_bits_uint buf, byteOffset * 8, 8

  # Read <len> bits from the bit position <pos> from the start of
  # the buffer <buf>, and return it as unsigned integer
  parse_bits_uint: (buffer, pos, len) ->
    byteIndex = parseInt pos / 8
    bitIndex = pos % 8
    consumedLen = 0
    num = 0

    while consumedLen < len
      consumedLen += 8 - bitIndex
      otherBitsLen = 0
      if consumedLen > len
        otherBitsLen = consumedLen - len
        consumedLen = len
      num += ((buffer[byteIndex] & ((1 << (8 - bitIndex)) - 1)) <<
        (len - consumedLen)) >> otherBitsLen
      byteIndex++
      bitIndex = 0
    return num

  toBinary: (byte) ->
    binString = ''
    for i in [7..0]
      binString += (byte >> i) & 0x01
    return binString

  printBinary: (buffer) ->
    col = 0
    for byte in buffer
      process.stdout.write api.toBinary byte
      col++
      if col is 4
        console.log()
        col = 0
      else
        process.stdout.write ' '
    if col isnt 0
      console.log()

module.exports = api
