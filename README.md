### RTSP, RTMP, and HTTP server in Node.js

- Acts as RTSP, RTMP/RTMPE/RTMPT/RTMPTE, and HTTP server.
- This server is supposed to receive audio/video packets via UNIX domain sockets.
- RTSP stream is viewable with Android's VideoView and VLC media player.
- RTMP stream is viewable with Flowplayer.

(Documentation is in progress)

### Installation

    $ git clone https://github.com/iizukanao/node-rtsp-rtmp-server.git
    $ cd node-rtsp-rtmp-server
    $ npm install -d

### Configuration

Edit config.coffee.

### Starting server

    $ cd node-rtsp-rtmp-server
    $ sudo coffee server.coffee

or use Node.js directly:

    $ cd node-rtsp-rtmp-server
    $ coffee -c .
    $ sudo node server.js

If `serverPort` is above 1023 in config.coffee, you can omit `sudo`.
