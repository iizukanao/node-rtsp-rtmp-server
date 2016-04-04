# Utility for Buffer operations

###
# Usage

    Bits = require './bits'
    
    # Reader
    buf = new Buffer [
      0b11010001
      0b11110000
      0x7f, 0xff, 0xff, 0xff
      0x80, 0x00, 0x00, 0x00
    ]
    myBits = new Bits buf  # A Bits instance holds a cursor
    console.log myBits.read_bit()
    # => 1
    console.log myBits.read_bits 2
    # => 2
    myBits.skip_bits 5
    console.log myBits.read_byte()  # Returns a number
    # => 240
    console.log myBits.read_bytes 2  # Returns a Buffer instance
    # => <Buffer 7f ff>
    myBits.push_back_bytes 2  # Move the cursor two bytes back
    console.log myBits.read_int 32
    # => 2147483647
    console.log myBits.read_int 32
    # => -2147483648
    
    # Writer
    myBits = new Bits()
    myBits.create_buf()
    myBits.add_bit 1         # 0b1_______
    myBits.add_bits 2, 1     # 0b101_____
    myBits.add_bits 5, 3     # 0b10100011
    myBits.add_bits 8, 0xff  # 0b10100011, 0b11111111
    resultArray = myBits.get_created_buf()  # Returns an array
    resultBuf = new Buffer resultArray
    Bits.printBinary resultBuf
    # => 10100011 11111111 
###

try
  buffertools = require 'buffertools'
catch e
  # buffertools is not available

class Bits
  constructor: (buffer) ->
    @buf = null
    @byte_index = 0
    @bit_index = 0

    @stash_buf = []
    @stash_byte_index = []
    @stash_bit_index = []

    @c_buf = null
    @c_byte_index = 0
    @c_bit_index = 0

    if buffer?
      @set_data buffer

  @DISABLE_BUFFER_INDEXOF: false

  @set_warning_fatal: (is_fatal) ->
    Bits.is_warning_fatal = is_fatal

  create_buf: ->
    @c_buf = []
    @c_byte_index = 0
    @c_bit_index = 0

  add_bit: (value) ->
    @add_bits 1, value

  # @param  numBits (int) number of bits to fill with 1
  fill_bits_with_1: (numBits) ->
    if numBits > 32
      throw new Error "numBits must be <= 32"
    value = Math.pow(2, numBits) - 1
    @add_bits numBits, value

  # value is up to 32-bit unsigned integer
  add_bits: (numBits, value) ->
    if value > 0xffffffff
      throw new Error "value must be <= 0xffffffff (uint32)"
    if value < 0
      throw new Error "value must be >= 0 (uint32)"
    remaining_len = numBits
    while remaining_len > 0
      if not @c_buf[@c_byte_index]?  # not initialized
        @c_buf[@c_byte_index] = 0x00  # initialize
      available_len = 8 - @c_bit_index
      if remaining_len <= available_len  # fits into current byte
        @c_buf[@c_byte_index] |= value << (available_len - remaining_len)
        @c_bit_index += remaining_len
        remaining_len = 0
        if @c_bit_index is 8
          @c_byte_index++
          @c_bit_index = 0
      else
        this_value = (value >>> (remaining_len - available_len)) & 0xff
        @c_buf[@c_byte_index] |= this_value
        remaining_len -= available_len
        @c_byte_index++
        @c_bit_index = 0

  # TODO: This method needs a better name, since it returns an array.
  # @return array
  get_created_buf: ->
    return @c_buf

  current_position: ->
    return {
      byte: @byte_index
      bit : @bit_index
    }

  print_position: ->
    remaining_bits = @get_remaining_bits()
    console.log "byteIndex=#{@byte_index+1} bitIndex=#{@bit_index} remaining_bits=#{remaining_bits}"

  peek: ->
    console.log @buf[@byte_index..]
    remainingBits = @get_remaining_bits()
    console.log "bit=#{@bit_index} bytes_read=#{@byte_index} remaining=#{remainingBits} bits (#{Math.ceil(remainingBits/8)} bytes)"

  skip_bits: (len) ->
    @bit_index += len
    while @bit_index >= 8
      @byte_index++
      @bit_index -= 8
    return

  skip_bytes: (len) ->
    @byte_index += len

  # Returns the number of skipped bytes
  skip_bytes_equal_to: (value) ->
    count = 0
    loop
      byte = @read_byte()
      if byte isnt value
        @push_back_byte()
        return count
      count++

  read_uint32: ->
    return @read_byte() * Math.pow(256, 3) +
           (@read_byte() << 16) +
           (@read_byte() << 8) +
           @read_byte()

  # Read a signed number represented by two's complement.
  # bits argument is the length of the signed number including
  # the sign bit.
  read_int: (bits) ->
    if bits < 0
      throw new Error "read_int: bits argument must be positive: #{bits}"
    if bits is 1
      return @read_bit()
    sign_bit = @read_bit()
    value = @read_bits bits - 1
    if sign_bit is 1  # negative number
      return -Math.pow(2, bits - 1) + value
    else  # positive number
      return value

  # unsigned integer Exp-Golomb-coded syntax element
  # see clause 9.1
  read_ue: ->
    return @read_exp_golomb()

  # signed integer Exp-Golomb-coded syntax element
  read_se: ->
    value = @read_exp_golomb()
    return Math.pow(-1, value + 1) * Math.ceil(value / 2)

  read_exp_golomb: ->
    leadingZeroBits = -1
    b = 0
    while b is 0
      b = @read_bit()
      leadingZeroBits++
    return Math.pow(2, leadingZeroBits) - 1 + @read_bits(leadingZeroBits)

  # Return an instance of Buffer
  read_bytes: (len, suppress_boundary_warning=0) ->
    if @bit_index isnt 0
      throw new Error "read_bytes: bit_index must be 0"

    if (not suppress_boundary_warning) and (@byte_index + len > @buf.length)
      errmsg = "read_bytes exceeded boundary: #{@byte_index+len} > #{@buf.length}"
      if Bits.is_warning_fatal
        throw new Error errmsg
      else
        console.log "warning: bits.read_bytes: #{errmsg}"

    range = @buf[@byte_index...@byte_index+len]
    @byte_index += len
    return range

  read_bytes_sum: (len) ->
    sum = 0
    for i in [len...0]
      sum += @read_byte()
    return sum

  read_byte: ->
    if @bit_index is 0
      if @byte_index >= @buf.length
        throw new Error "read_byte error: no more data"
      value = @buf[@byte_index++]
    else
      value = @read_bits 8
    return value

  read_bits: (len) ->
    if len is 0
      return 0

    bit_buf = ''
    for i in [0...len]
      bit_buf += @read_bit().toString()
    return parseInt bit_buf, 2

  read_bit: ->
    if @byte_index >= @buf.length
      throw new Error "read_bit error: no more data"
    value = @bit @bit_index++, @buf[@byte_index]
    if @bit_index is 8
      @byte_index++
      @bit_index = 0
    return value

  push_back_byte: ->
    @push_back_bytes 1

  push_back_bytes: (len) ->
    @push_back_bits len * 8

  push_back_bits: (len) ->
    while len-- > 0
      @bit_index--
      if @bit_index is -1
        @bit_index = 7
        @byte_index--
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
    @stash_buf.push @buf
    @stash_byte_index.push @byte_index
    @stash_bit_index.push @bit_index

  pop_stash: ->
    @buf = @stash_buf.pop()
    @byte_index = @stash_byte_index.pop()
    @bit_index = @stash_bit_index.pop()

  set_data: (bytes) ->
    @buf = bytes
    @byte_index = 0
    @bit_index = 0

  has_more_data: ->
    return @get_remaining_bits() > 0

  get_remaining_bits: ->
    total_bits = @buf.length * 8
    total_read_bits = @byte_index * 8 + @bit_index
    return total_bits - total_read_bits

  get_remaining_bytes: ->
    if @bit_index isnt 0
      console.warn "warning: bits.get_remaining_bytes: bit_index is not 0"
    remainingLen = @buf.length - @byte_index
    if remainingLen < 0
      remainingLen = 0
    return remainingLen

  remaining_buffer: ->
    if @bit_index isnt 0
      console.warn "warning: bits.remaining_buffer: bit_index is not 0"
    return @buf[@byte_index..]

  is_byte_aligned: ->
    return @bit_index is 0

  read_until_byte_aligned: ->
    sum = 0
    while @bit_index isnt 0
      sum += @read_bit()
    return sum

  # @param bitVal (number)  0 or 1
  #
  # @return object or null  If rbsp_stop_one_bit is found,
  # returns an object {
  #   byte: (number) byte index (starts from 0)
  #   bit : (number) bit index (starts from 0)
  # }. If it is not found, returns null.
  lastIndexOfBit: (bitVal) ->
    for i in [@buf.length-1..@byte_index]
      byte = @buf[i]
      if (bitVal is 1 and byte isnt 0x00) or (bitVal is 0 and byte isnt 0xff)
        # this byte contains the target bit
        for col in [0..7]
          if ((byte >> col) & 0x01) is bitVal
            return byte: i, bit: 7 - col
          if (i is @byte_index) and (7 - col is @bit_index)
            return null
    return null  # not found

  get_current_byte: ->
    return @get_byte_at 0

  get_byte_at: (byteOffset) ->
    if @bit_index is 0
      return @buf[@byte_index + byteOffset]
    else
      Bits.parse_bits_uint @buf, byteOffset * 8, 8

  last_get_byte_at: (offsetFromEnd) ->
    offsetFromStart = @buf.length - 1 - offsetFromEnd
    if offsetFromStart < 0
      throw new Error "error: last_get_byte_at: index out of range"
    return @buf[offsetFromStart]

  remove_trailing_bytes: (numBytes) ->
    if @buf.length < numBytes
      console.warn "warning: bits.remove_trailing_bytes: Buffer length (#{@buf.length}) is less than numBytes (#{numBytes})"
      @buf = new Buffer []
    else
      @buf = @buf[0...@buf.length-numBytes]
    return

  mark: ->
    if not @marks?
      @marks = [ @byte_index ]
    else
      @marks.push @byte_index

  marked_bytes: ->
    if (not @marks?) or (@marks.length is 0)
      throw new Error "The buffer has not been marked"
    startIndex = @marks.pop()
    return @buf[startIndex..@byte_index-1]

  # Returns a null-terminated string
  get_string: (encoding='utf8') ->
    nullPos = Bits.searchByteInBuffer @buf, 0x00, @byte_index
    if nullPos is -1
      throw new Error "bits.get_string: the string is not null-terminated"
    str = @buf[@byte_index...nullPos].toString encoding
    @byte_index = nullPos + 1
    return str

  # Returns a string constructed by a number
  @uintToString: (num, numBytes, encoding='utf8') ->
    arr = []
    for i in [numBytes..1]
      arr.push (num * Math.pow(2, -(i-1)*8)) & 0xff
    return new Buffer(arr).toString encoding

  # Returns the first index at which a given value (byte) can be
  # found in the Buffer (buf), or -1 if it is not found.
  @searchByteInBuffer: (buf, byte, from_pos=0) ->
    if (not Bits.DISABLE_BUFFER_INDEXOF) and (typeof(buf.indexOf) is 'function')
      return buf.indexOf byte, from_pos
    else
      if from_pos < 0
        from_pos = buf.length + from_pos
      for i in [from_pos...buf.length]
        if buf[i] is byte
          return i
      return -1

  @searchBytesInArray: (haystack, needle, from_pos=0) ->
    if buffertools?  # buffertools is available
      if haystack not instanceof Buffer
        haystack = new Buffer haystack
      if needle not instanceof Buffer
        needle = new Buffer needle
      return buffertools.indexOf haystack, needle, from_pos
    else  # buffertools is not available
      haystack_len = haystack.length
      if from_pos >= haystack_len
        return -1

      needle_idx = 0
      needle_len = needle.length
      haystack_idx = from_pos
      loop
        if haystack[haystack_idx] is needle[needle_idx]
          needle_idx++
          if needle_idx is needle_len
            return haystack_idx - needle_len + 1
        else if needle_idx > 0
          haystack_idx -= needle_idx
          needle_idx = 0
        haystack_idx++
        if haystack_idx is haystack_len
          return -1

  @searchBitsInArray: (haystack, needle, fromPos=0) ->
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

  # Read <len> bits from the bit position <pos> from the start of
  # the buffer <buf>, and return it as unsigned integer
  @parse_bits_uint: (buffer, pos, len) ->
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

  @toBinary: (byte) ->
    binString = ''
    for i in [7..0]
      binString += (byte >> i) & 0x01
    return binString

  @printBinary: (buffer) ->
    col = 0
    for byte in buffer
      process.stdout.write Bits.toBinary byte
      col++
      if col is 4
        console.log()
        col = 0
      else
        process.stdout.write ' '
    if col isnt 0
      console.log()

  @getHexdump: (buffer) ->
    col = 0
    strline = ''
    dump = ''

    endline = ->
      pad = '  '
      while col < 16
        pad += '  '
        if col % 2 is 0
          pad += ' '
        col++
      dump += pad + strline + '\n'
      strline = ''

    for byte in buffer
      if 0x20 <= byte <= 0x7e  # printable char
        strline += String.fromCharCode byte
      else
        strline += ' '
      dump += Bits.zeropad(2, byte.toString(16))
      col++
      if col is 16
        endline()
        col = 0
      else if col % 2 is 0
        dump += ' '
    if col isnt 0
      endline()

    return dump

  @hexdump: (buffer) ->
    process.stdout.write Bits.getHexdump buffer

  @zeropad: (width, num) ->
    num += ''
    while num.length < width
      num = '0' + num
    num

module.exports = Bits
