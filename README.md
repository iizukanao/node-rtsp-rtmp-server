### RTSP, RTMP, and HTTP server in Node.js

- Supports RTSP, RTMP/RTMPE/RTMPT/RTMPTE, and HTTP.
- Supports only H.264 video and AAC audio (AAC-LC, HE-AAC v1/v2).

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
- **Stream**: STREAM_NAME (whatever name you would like)

Press the "Connect" button. Set the video format to H.264, and the audio format to AAC. Press the "Start" button.

When you watch the stream over RTSP or RTMP, use the stream name specified above.

#### From FFmpeg

If you have an MP4 file with H.264 video and AAC audio:

    $ ffmpeg -re -i input.mp4 -c:v copy -c:a copy -f flv rtmp://localhost/live/STREAM_NAME

Or if you have an MP4 file that is encoded in other audio/video format:

    $ ffmpeg -re -i input.mp4 -c:v libx264 -preset fast -c:a libfdk_aac -ab 128k -ar 44100 -f flv rtmp://localhost/live/STREAM_NAME

Replace `input.mp4` with live audio/video sources.

#### From RTSP client

You can publish streams from RTSP client such as FFmpeg.

    $ ffmpeg -re -i input.mp4 -c:v libx264 -preset fast -c:a libfdk_aac -ab 128k -ar 44100 -f rtsp rtsp://localhost:80/live/STREAM_NAME

Or you can publish it over TCP instead of UDP, by specifying `-rtsp_transport tcp` option. TCP is favorable if you publish large data from FFmpeg.

    $ ffmpeg -re -i input.mp4 -c:v libx264 -preset fast -c:a libfdk_aac -ab 128k -ar 44100 -f rtsp -rtsp_transport tcp rtsp://localhost:80/live/STREAM_NAME

#### From GStreamer

For an MP4 file with H.264 video and AAC audio:

    $ gst-launch-0.10 filesrc location=input.mp4 ! qtdemux name=demux ! \
        flvmux name=mux streamable=true ! queue ! \
        rtmpsink location='rtmp://localhost/live/STREAM_NAME' demux. ! \
        multiqueue name=mq ! h264parse ! mux. demux. ! mq. mq. ! aacparse ! mux.

Replace `input.mp4` with live audio/video sources.

### Accessing the live stream

#### Via RTSP

RTSP stream is for VLC media player or Android's VideoView.

**RTSP URL**: rtsp://localhost:80/live/STREAM_NAME

Note that the RTSP server runs on port 80 by default.

#### Via RTMP

RTMP stream is for Flash Player. Flowplayer and JW Player are both good free players.

**RTMP URL**: rtmp://localhost/live/STREAM_NAME

If you have rtmpdump installed, you can record the video with:

    $ rtmpdump -v -r rtmp://localhost/live/STREAM_NAME -o dump.flv
