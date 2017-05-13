FROM node:7.10.0

RUN apt-get update && \
    apt-get install -y sudo git wget curl make && \
	git clone https://github.com/dapphub/seth && \
	git clone https://github.com/dapphub/dapp && \
	make link -C seth && \
	make link -C dapp && \
	wget https://github.com/dapphub/ethrun/releases/download/v0.2.4/ethrun-v0.2.4-linux.tar.gz && \
	tar xfz ethrun-v0.2.4-linux.tar.gz && \
	mv ethrun /usr/local/bin/ethrun && \
	chmod +x /usr/local/bin/ethrun && \
	rm -rf ethrun-v0.2.4-linux.tar.gz && \
	wget https://github.com/ethereum/solidity/releases/download/v0.4.11/solc-static-linux && \
	sudo mv solc-static-linux /usr/local/bin/solc && \
	chmod +x /usr/local/bin/solc && \
	echo "node ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

USER node
ENV USER node
ENV HOME /home/node

WORKDIR /home/node

RUN curl https://nixos.org/nix/install | bash
RUN /nix/var/nix/profiles/default/bin/nix-env -i ethabi jshon

VOLUME /home/node/workspace
WORKDIR /home/node/workspace
CMD [ "dapp", "test"]