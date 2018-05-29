### RTSP, RTMP, and HTTP server in Node.js

- Supports RTSP, RTMP/RTMPE/RTMPT/RTMPTE, and HTTP.
- Supports only H.264 video and AAC audio (AAC-LC, HE-AAC v1/v2).

### Installation without Docker

    $ git clone https://github.com/iizukanao/node-rtsp-rtmp-server.git
    $ cd node-rtsp-rtmp-server
    $ npm install -d

Also, install [CoffeeScript](https://coffeescript.org/) 1.x or 2.x.

### Configuration

Edit `config.coffee`.

### Starting the server

    $ cd node-rtsp-rtmp-server
    $ sudo coffee server.coffee

or use Node.js directly:

    $ cd node-rtsp-rtmp-server
    $ coffee -c *.coffee
    $ sudo node server.js

If both `serverPort` and `rtmpServerPort` are >= 1024 in `config.coffee`, `sudo` is not needed.

### Docker Deploy Method

If you would prefer building and executing this code in a docker container, you can do so by first building the container and then running it.

    $  make build
    $  make console

You may also want to use just `make run` to run the container as a daemon.  If you fiddle with the ports, you'll need to update the values in the Makefile as well to expose the desired ports to your system.

### Serving MP4 files as recorded streams

MP4 files in `file` directory will be accessible at either:

- rtsp://localhost:80/file/FILENAME
- rtmp://localhost/file/mp4:FILENAME

For example, file/video.mp4 is available at rtmp://localhost/file/mp4:video.mp4

### Publishing live streams

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

For an RTSP source (at rtsp://192.168.1.1:5000/video1  in this example):

    $ gst-launch-0.10 rtspsrc location=rtsp://192.168.1.1:5000/video1 ! decodebin ! \
        x264enc bitrate=256 tune=zerolatency  ! h264parse ! flvmux name=mux streamable=true ! \
        queue ! rtmpsink location='rtmp://localhost/live/STREAM_NAME' 

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
