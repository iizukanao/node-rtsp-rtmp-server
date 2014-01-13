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

### Starting server

    $ cd node-rtsp-rtmp-server
    $ coffee server.coffee

or:

    $ cd node-rtsp-rtmp-server
    $ coffee -c .
    $ node server.js
