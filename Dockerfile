FROM ubuntu:22.04

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get -y install \
    build-essential cmake \
    curl wget vim python3 python3-pip \
    git pkg-config libssl-dev software-properties-common \
    unzip tar

RUN apt-get update

# Install smt-solvers: (1) cvc5
RUN mkdir cvc5-solver \
  && cd cvc5-solver \
  && wget https://github.com/cvc5/cvc5/releases/download/cvc5-1.0.4/cvc5-Linux \
  && mv cvc5-Linux cvc5 \
  && chmod +x cvc5


ENV PATH=/cvc5-solver:$PATH

# (2) Z3
RUN wget https://github.com/Z3Prover/z3/releases/download/z3-4.12.1/z3-4.12.1-x64-glibc-2.35.zip \
  && unzip z3-4.12.1-x64-glibc-2.35.zip \
  && rm z3-4.12.1-x64-glibc-2.35.zip \
  && mv z3-4.12.1-x64-glibc-2.35 z3 

ENV PATH=/z3/bin:$PATH

# Download hevm binary
RUN mkdir hevm && cd hevm \
  && wget https://github.com/ethereum/hevm/releases/download/release%2F0.50.4/hevm-x86_64-linux \
  && mv hevm-x86_64-linux hevm \
  && chmod +x hevm

ENV PATH=/hevm:$PATH

# Install solc through solc-select
RUN pip install solc-select \
  && solc-select install 0.8.17 \
  && solc-select use 0.8.17

ENTRYPOINT ["/bin/bash"]