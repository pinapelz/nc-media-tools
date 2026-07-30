These are a generic set of tools/helpers for running some sort of media service accessible over WebDAV. Its reccomended you run them from Google Colab to take advantage of fast download/upload speeds. Instructions provided in each notebook.

For Jupyter Notebooks, please refer to the information within each one for more info

# Shell Scripts
Below is a description of each available shell script. A `help()` command is also available in each one.

## grab.sh
Grabar is a bridge bash script that allows you to download some file via aria2c and then upload it after via rclone to any source you've configured. Optionally uses ntfy for notifications

## burnsubs.sh
Given a directory, for each pair of media and subtitle file, produce a new video where the subtitle is burned onto the media. Style is customizeable, requires `ffmpeg`
