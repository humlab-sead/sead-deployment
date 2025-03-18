#FROM debian:bookworm
FROM postgis/postgis:16-3.4

RUN apt-get update

RUN apt-get install -y git curl sqitch

WORKDIR /

RUN git clone https://github.com/humlab-sead/sead_change_control

#this might be needed by the sead_change_control deploy script, not sure
RUN ln -s /sead_change_control /repo

WORKDIR /sead_change_control

# Add sead_change_control/bin to PATH
ENV PATH="/sead_change_control/bin:$PATH"
