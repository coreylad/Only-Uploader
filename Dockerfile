FROM python:3.12

# Update the package list and install system dependencies including mono
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ffmpeg \
    mediainfo=23.04-1 \
    git \
    g++ \
    cargo \
    mktorrent \
    rustc \
    mono-complete && \
    rm -rf /var/lib/apt/lists/*

# Set up a virtual environment to isolate our Python dependencies
RUN python -m venv /venv
ENV PATH="/venv/bin:$PATH"

# Install wheel and other Python dependencies
RUN pip install --upgrade pip wheel

# Set the working directory in the container
WORKDIR /Only-Uploader

# Copy the Python requirements file and install Python dependencies
COPY requirements.txt .
RUN pip install -r requirements.txt

# Copy the rest of the application's code
COPY . .

# Expose the web panel port
EXPOSE 5000

# Default: CLI mode. Override with `entrypoint` in docker-compose.yml for web mode.
ENTRYPOINT ["python", "/Only-Uploader/upload.py"]