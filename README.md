### RTSP, RTMP, and HTTP server in Node.js

- Supports RTSP, RTMP/RTMPE/RTMPT/RTMPTE, and HTTP.
- Supports only H.264 video and AAC audio.
- Supports only a single pair of audio/video streams.

### Installation

    $ git clone https://github.com/iizukanao/node-rtsp-rtmp-server.git
    $ cd node-rtsp-rtmp-server
    $ npm install -d

### Configuration

Edit config.coffee.

### Starting the server

    $ cd node-rtsp-rtmp-server
    $ sudo coffee server.coffee

or use Node.js directly:

    $ cd node-rtsp-rtmp-server
    $ coffee -c .
    $ sudo node server.js

If `serverPort` is above 1023 in config.coffee, you can omit `sudo`.

### Publishing streams

#### From Flash Media Live Encoder

Flash Media Live Encoder is a free live encoder from Adobe.

In the Encoding Options panel, check "Stream to Flash Media Server" and set the URL to:

- **FMS URL**:  rtmp://localhost/live
- **Backup URL**: (blank)
- **Stream**: myStream (or whatever you like)

Press the "Connect" button. Set the video format to H.264, and the audio format to AAC. Press the "Start" button.

Note that multiple streams are not supported. You can push only one stream at a time.

#### From FFmpeg

If you have an MP4 file with H.264 video and AAC audio:

    $ ffmpeg -re -i input.mp4 -c:v copy -c:a copy -f flv rtmp://localhost/live/myStream

Or if you have an MP4 file that contains other audio/video codecs:

    $ ffmpeg -re -i input.mp4 -c:v libx264 -preset fast -c:a libfdk_aac -ab 128k -ar 44100 -f flv rtmp://localhost/live/myStream

Replace `input.mp4` with live audio/video sources.

#### From GStreamer

For an MP4 file with H.264 video and AAC audio:

    $ gst-launch-0.10 filesrc location=input.mp4 ! qtdemux name=demux ! \
        flvmux name=mux streamable=true ! queue ! \
        rtmpsink location='rtmp://localhost/live/myStream' demux. ! \
        multiqueue name=mq ! h264parse ! mux. demux. ! mq. mq. ! aacparse ! mux.

Replace `input.mp4` with live audio/video sources.

### Accessing the live stream

#### Via RTSP

RTSP stream is for VLC media player or Android's VideoView.

RTSP URL: rtsp://localhost:80/live

Note that the RTSP server runs on port 80 by default.

#### Via RTMP

RTMP stream is for Flash Player. Flowplayer and JW Player are both good free players.

RTMP URL: rtmp://localhost/live/myStream

If you have rtmpdump installed, you can record the video with:

    $ rtmpdump -v -r rtmp://localhost/live/myStream -o dump.flv
