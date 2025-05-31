# openconnect-socks
将openconnect连接的VPN通过socks5代理暴露出来



# use
```ymal
version: "3.8"
services:
  myvpn:
    image: xsdhy/openconnect-socks:latest
    container_name: myvpn
    privileged: true
    ports:
      - 11080:11080
    volumes:
      - ./certificate.p12:/app/certificate.p12
    environment:
      - VPN_PASSWORD=
      - VPN_SERVER=
      - TEST_URL=
```