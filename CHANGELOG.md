Change Log
==========

Version 0.4.0 *(2015-12-15)*
-----------------------------

- The server can now serves MP4 files as recorded streams.
- Fixed many bugs.


Version 0.3.1 *(2015-04-28)*
-----------------------------

- RTMP server port is now customizable via config.coffee.
- RTMPServer.start() now takes two arguments.
- Send an EOS (end of stream) signal when uploading is finished.
- Add support for HE-AAC v1/v2.
- Add support for incoming STAP-A RTP packets.
- Add rtmpWaitForKeyFrame to config.coffee.
- Use buffertools module if available.
- Other bug fixes.
