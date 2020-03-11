FROM robcurrie/jupyter-cpu

# Install the aws config plugin and braingeneerspy.
RUN pip install awscli-plugin-endpoint git+git://github.com/braingeneers/braingeneerspy
