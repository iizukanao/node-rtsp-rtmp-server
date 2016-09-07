FROM node:4-onbuild

################
#  App Deps    #
################

RUN mkdir /app
WORKDIR /app

# TODO:
# Copy over your application stuff required to load up
# dependencies and then install those dependencies

ADD package.json /app/package.json
RUN npm install -d
RUN npm install -g coffee-script


################
#  App Source  #
################

# Copy over your apps sourcecode in this section
COPY . /app/


#############
#  Conclude #
#############

COPY entrypoint.sh /sbin/entrypoint.sh
RUN chmod +x /sbin/entrypoint.sh
RUN echo ". /sbin/entrypoint.sh" > /root/.bash_history

ENTRYPOINT ["/sbin/entrypoint.sh"]
