DOCKER_IMAGE_NAME = node-rtsp-rtmp-server

build:
	docker build -t ${USER}/${DOCKER_IMAGE_NAME} .

# If you have to configure volumes, do that from here
# configure:

run:
	(docker start ${DOCKER_IMAGE_NAME}) || \
	docker run \
  -p 80:80 -p 1935:1935 \
  --name ${DOCKER_IMAGE_NAME} -d ${USER}/${DOCKER_IMAGE_NAME}

console:
	docker run -it \
  -p 80:80 -p 1935:1935 \
  -e an_env_var=${HIDDEN_ENV} \
  ${USER}/${DOCKER_IMAGE_NAME} bash

.PHONY: build
