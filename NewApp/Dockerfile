# .NET API Dockerfile — with OpenTelemetry Auto-Instrumentation
# Multi-stage build for optimized production image

# Stage 1: Build
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /src

# Copy csproj and restore dependencies
COPY NewApp.csproj .
RUN dotnet restore

# Copy source code and build
COPY . .
RUN dotnet publish -c Release -o /app/publish

# Stage 2: Runtime with OTel Auto-Instrumentation
FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS runtime
WORKDIR /app

# Install dependencies for auto-instrumentation
RUN apt-get update && apt-get install -y --no-install-recommends \
    unzip curl \
    && rm -rf /var/lib/apt/lists/*

# Download and install OTel .NET Auto-Instrumentation
ARG OTEL_VERSION=1.12.0
RUN curl -sSfL https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/download/v${OTEL_VERSION}/otel-dotnet-auto-install.sh -o otel-dotnet-auto-install.sh \
    && OTEL_DOTNET_AUTO_HOME="/otel-dotnet-auto" sh otel-dotnet-auto-install.sh \
    && rm otel-dotnet-auto-install.sh

# Detect architecture and set profiler path
ARG TARGETARCH
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "arm64" || echo "x64") && \
    echo "PROFILER_ARCH=$ARCH" > /tmp/otel-arch.env

# CLR Profiler environment variables (enables auto-instrumentation)
ENV CORECLR_ENABLE_PROFILING=1
ENV CORECLR_PROFILER={918728DD-259F-4A6A-AC2B-B85E1B658318}
ENV DOTNET_ADDITIONAL_DEPS=/otel-dotnet-auto/AdditionalDeps
ENV DOTNET_SHARED_STORE=/otel-dotnet-auto/store
ENV DOTNET_STARTUP_HOOKS=/otel-dotnet-auto/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll
ENV OTEL_DOTNET_AUTO_HOME=/otel-dotnet-auto

# Set profiler path based on detected arch (arm64 or x64)
RUN ARCH=$([ "$(uname -m)" = "aarch64" ] && echo "arm64" || echo "x64") && \
    echo "CORECLR_PROFILER_PATH=/otel-dotnet-auto/linux-${ARCH}/OpenTelemetry.AutoInstrumentation.Native.so" >> /etc/environment && \
    ln -sf /otel-dotnet-auto/linux-${ARCH}/OpenTelemetry.AutoInstrumentation.Native.so /otel-dotnet-auto/profiler.so
ENV CORECLR_PROFILER_PATH=/otel-dotnet-auto/profiler.so

# OTel configuration defaults (overridable via docker-compose / K8s)
ENV OTEL_SERVICE_NAME=newapp
ENV OTEL_TRACES_EXPORTER=otlp
ENV OTEL_METRICS_EXPORTER=none
ENV OTEL_LOGS_EXPORTER=none
ENV OTEL_DOTNET_AUTO_TRACES_ADDITIONAL_SOURCES=NewApp

# Copy published app from build stage
COPY --from=build /app/publish .

# Expose port
EXPOSE 8080

# Set environment variables
ENV ASPNETCORE_URLS=http://+:8080
ENV ASPNETCORE_ENVIRONMENT=Production

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:8080/api/health || exit 1

# Run the application
ENTRYPOINT ["dotnet", "NewApp.dll"]
