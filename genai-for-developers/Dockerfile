# Use a lightweight Python base image
FROM python:3.9-slim


# Install git, curl, jq, gawk, and necessary build tools
# We keep build-essential as some dependencies might need it

RUN apt-get update && \
    apt-get install -y --no-install-recommends git curl jq gawk build-essential && \
    rm -rf /var/lib/apt/lists/* # Clean up apt lists

# Allow statements and log messages to immediately appear in the Knative logs
ENV PYTHONUNBUFFERED True

# Set the working directory
WORKDIR /app

# Copy the local devai/src directory into the /app directory in the image
# This assumes your Dockerfile is at the root of your project
# and the devai-cli source is in ./devai/src relative to the Dockerfile
COPY ./devai-cli /app/devai-cli

# Clone the genai-for-developers repository
#RUN git clone https://github.com/GoogleCloudPlatform/genai-for-developers.git /tmp/genai-for-developers
#RUN git clone https://git.planetgroupint.com/internal/genai-for-developers.git /tmp/genai-for-developers 


# Install devai-cli from the cloned repository source directory
# We also include the other explicit dependencies you identified

RUN pip install -r /app/devai-cli/src/requirements.txt

RUN pip install --no-cache-dir /app/devai-cli/src

RUN cp -r /app/devai-cli/src/prompts /app/prompts

# Clean up the cloned repository to reduce image size
RUN rm -rf /app/devai-cli


