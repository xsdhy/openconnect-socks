

docker build -t openconnect-socks .

docker build --platform=linux/amd64 -t openconnect-socks .

docker buildx create --use
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t xsdhy/openconnect-socks:latest \
  --push .