################################################################
# Stage 1: Build ArangoDB from sources (Debian)
################################################################
ARG TAG=v3.11.14
FROM debian:12 AS builder
ARG TAG

# 1) Установим инструменты для сборки
RUN apt-get update && apt-get install --no-install-recommends -y \
      build-essential cmake \
      clang-16 lld-16 llvm-16 libomp-16-dev \
      libopenblas-dev libssl-dev \
      python3 python3-clang-16 libabsl-dev \
      git-core wget unzip tar nodejs npm && \
    npm config set audit=false && \
    npm config set strict-ssl false && \
    npm install --global yarn && \
    apt-get clean -y

# 2) Клонируем ArangoDB по нужному TAG со всеми сабмодулями
RUN git clone --branch ${TAG} --depth 1 --recurse-submodules \
      https://github.com/arangodb/arangodb.git /opt/arangodb/src


# 2.1) Копируем патчи из контекста сборки в контейнер
COPY patches /opt/arangodb/src/patches

# 2.2) Применяем все патчи
RUN cd /opt/arangodb/src && \
  for p in patches/*.patch; do \
    echo "Applying $p…"; \
    git apply -p1 --ignore-space-change --ignore-whitespace "$p"; \
  done

# 3) Собираем и устанавливаем в /opt/arangodb-${TAG}
RUN mkdir /opt/arangodb/build && cd /opt/arangodb/build && \
    cmake /opt/arangodb/src \
      -DCMAKE_C_COMPILER=/usr/bin/clang-16 \
      -DCMAKE_CXX_COMPILER=/usr/bin/clang++-16 \
      -DCMAKE_C_COMPILER_AR="/usr/bin/llvm-ar-16" \
      -DCMAKE_CXX_COMPILER_AR="/usr/bin/llvm-ar-16" \
      -DCMAKE_C_COMPILER_RANLIB="/usr/bin/llvm-ranlib-16" \
      -DCMAKE_CXX_COMPILER_RANLIB="/usr/bin/llvm-ranlib-16" \
      -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld-16 -fopenmp" \
      -DCMAKE_INSTALL_PREFIX=/opt/arangodb-${TAG} \
      -DCMAKE_BUILD_TYPE=Release \
      -DUSE_FAIL_ON_WARNINGS=off \
      -DUSE_GOOGLE_TESTS=off \
      -DUSE_MAINTAINER_MODE=off \
      -DUSE_JEMALLOC=Off \
      -DCMAKE_C_FLAGS='-w -std=c11 -fopenmp' \
      -DCMAKE_CXX_FLAGS='-w -std=c++17 -fopenmp' && \
    make -j"$(nproc)" install

################################################################
# Stage 2: Official-style runtime (Alpine)
################################################################
FROM alpine:3.21

LABEL maintainer="Qubership <bot@qubership.com>"

ARG TAG
ENV ARANGO_VERSION=${TAG} \
    GLIBCXX_FORCE_NEW=1

# 1) Устанавливаем рантайм-зависимости и foxx-cli
RUN apk add --no-cache \
      gnupg pwgen binutils numactl numactl-tools \
      nodejs yarn && \
    yarn global add foxx-cli@2.1.1 && \
    apk del yarn && \
    mkdir -p /docker-entrypoint-initdb.d

# 2) Копируем собранный артефакт из билд-стадии
COPY --from=builder /opt/arangodb-${TAG} /opt/arangodb-${TAG}

# 3) Делаем arangod доступным в PATH
RUN ln -s /opt/arangodb-${TAG}/sbin/arangod /usr/bin/arangod

# 4) Настраиваем конфигурацию, чтобы слушать на 0.0.0.0
RUN sed -ri \
      -e 's!127\.0\.0\.1!0.0.0.0!g' \
      -e 's!^(file\s*=\s*).*!\1 -!g' \
      -e 's!^\s*uid\s*=.*!!g' \
      /opt/arangodb-${TAG}/etc/arangodb3/arangod.conf

# 5) Права на каталоги данных и приложений
RUN mkdir -p /var/lib/arangodb3 /var/lib/arangodb3-apps && \
    chgrp -R 0 /var/lib/arangodb3 /var/lib/arangodb3-apps && \
    chmod -R 775 /var/lib/arangodb3 /var/lib/arangodb3-apps

# 6) Часовой пояс и тома (как в официальном Dockerfile)
RUN echo "UTC" > /etc/timezone
VOLUME ["/var/lib/arangodb3", "/var/lib/arangodb3-apps"]

# 7) Копируем официальные entrypoint'ы
COPY docker-entrypoint.sh /entrypoint.sh
COPY docker-foxx.sh /usr/bin/foxx
RUN chmod +x /entrypoint.sh /usr/bin/foxx

EXPOSE 8529
ENTRYPOINT ["/entrypoint.sh"]
CMD ["arangod"]
