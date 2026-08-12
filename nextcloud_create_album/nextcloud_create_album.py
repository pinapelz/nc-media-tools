import argparse
import base64
import json
import os
import sys
from pathlib import Path
from typing import Any
from urllib.parse import quote
from xml.etree import ElementTree
from dotenv import load_dotenv
from mutagen.flac import FLAC
import requests
from tqdm import tqdm

load_dotenv()


def upload_to_nextcloud(
    file_path: str | Path,
    remote_path: str,
    nextcloud_url: str | None = None,
    username: str | None = None,
    password: str | None = None,
) -> str:
    nextcloud_url = (nextcloud_url or os.environ["NEXTCLOUD_URL"]).rstrip("/")
    username = username or os.environ["NEXTCLOUD_USERNAME"]
    password = password or os.environ["NEXTCLOUD_PASSWORD"]

    file_path = Path(file_path)

    if not file_path.is_file():
        raise FileNotFoundError(file_path)
    remote_path = remote_path.strip("/")
    dav_base = (
        f"{nextcloud_url}/remote.php/dav/files/"
        f"{quote(username, safe='')}"
    )
    current_path = dav_base

    for directory in remote_path.split("/"):
        current_path += f"/{quote(directory)}"

        response = requests.request(
            "MKCOL",
            current_path,
            auth=(username, password),
        )

        # 201 = created
        # 405 = already exists
        if response.status_code not in (201, 405):
            raise RuntimeError(
                f"Failed to create directory '{directory}': "+
                f"{response.status_code} {response.text}"
            )
    filename = file_path.name

    upload_url = (
        f"{dav_base}/"
        f"{'/'.join(quote(p) for p in remote_path.split('/'))}/"
        f"{quote(filename)}"
    )

    with file_path.open("rb") as f:
        response = requests.put(
            upload_url,
            auth=(username, password),
            data=f,
            headers={
                "Content-Type": "application/octet-stream",
            },
        )

    if response.status_code not in (200, 201, 204):
        raise RuntimeError(
            f"Failed to upload file: " +
            f"{response.status_code} {response.text}"
        )
    share_api = (
        f"{nextcloud_url}/ocs/v2.php/apps/files_sharing/"
        f"api/v1/shares"
    )
    share_path = f"/{remote_path}/{filename}"
    response = requests.post(
        share_api,
        auth=(username, password),
        headers={
            "OCS-APIRequest": "true",
            "Accept": "application/xml",
        },
        data={
            "path": share_path,
            "shareType": "3",   # Public link
            "permissions": "1", # Read-only
        },
    )
    if not response.ok:
        raise RuntimeError(
            f"Failed to create share: " +
            f"{response.status_code} {response.text}"
        )

    try:
        root = ElementTree.fromstring(response.text)

        url_element = root.find(".//url")

        if url_element is None or not url_element.text:
            raise RuntimeError(
                f"Share was created but no URL was returned: "+
                f"{response.text}"
            )

        return url_element.text

    except ElementTree.ParseError as e:
        raise RuntimeError(
            f"Invalid response from Nextcloud: {response.text}"
        ) from e


def get_all_flac_files(directory: str) -> list[str]:
    flac_files = []
    for root, _, files in os.walk(directory):
        for file in files:
            if file.endswith(".flac"):
                flac_files.append(os.path.join(root, file))
    return flac_files


def get_flac_metadata(file_path: str | Path) -> dict[str, Any]:
    audio = FLAC(str(file_path))
    return {
        "title": audio.get("title", [None])[0],
        "artist": audio.get("artist", [None])[0],
        "album": audio.get("album", [None])[0],
    }


def main():
    parser = argparse.ArgumentParser(
        description="Upload an album folder (FLAC files + cover.jpg) to Nextcloud and output base64-encoded album JSON."
    )
    _ = parser.add_argument(
        "folder",
        type=str,
        help="Path to local folder containing FLAC files and cover.jpg"
    )
    _ = parser.add_argument(
        "remote_path",
        type=str,
        help="Destination remote path on Nextcloud"
    )
    _ = parser.add_argument(
        "--nextcloud-url",
        type=str,
        default=None,
        help="Nextcloud base URL"
    )
    _ = parser.add_argument(
        "--username",
        type=str,
        default=None,
        help="Nextcloud username"
    )
    _ = parser.add_argument(
        "--password",
        type=str,
        default=None,
        help="Nextcloud password"
    )

    args = parser.parse_args()

    local_dir = Path(args.folder)
    if not local_dir.is_dir():
        raise NotADirectoryError(f"Local directory not found: {local_dir}")

    cover_path = local_dir / "cover.jpg"
    if not cover_path.is_file():
        raise FileNotFoundError(f"cover.jpg not found in {local_dir}")

    print(f"Scanning '{local_dir}' for FLAC files...", file=sys.stderr)
    flac_files = get_all_flac_files(str(local_dir))
    if not flac_files:
        raise RuntimeError(f"No FLAC files found in {local_dir}")

    flac_files = sorted(flac_files)
    print(f"Found {len(flac_files)} FLAC track(s).", file=sys.stderr)
    print("Uploading cover.jpg...", file=sys.stderr)
    cover_url = upload_to_nextcloud(
        cover_path,
        args.remote_path,
        nextcloud_url=args.nextcloud_url,
        username=args.username,
        password=args.password,
    )
    cover_url = cover_url.rstrip("/")
    if not cover_url.endswith("/download"):
        cover_url += "/download"
    print("Cover uploaded and shared successfully.", file=sys.stderr)

    album_name = None
    artist = None
    tracks = []

    with tqdm(flac_files, desc="Uploading tracks", unit="track") as pbar:
        for flac_file in pbar:
            track_path = Path(flac_file)
            pbar.set_postfix(file=track_path.name)

            meta = get_flac_metadata(flac_file)
            if not album_name and meta.get("album"):
                album_name = meta["album"]
            if not artist and meta.get("artist"):
                artist = meta["artist"]

            track_url = upload_to_nextcloud(
                flac_file,
                args.remote_path,
                nextcloud_url=args.nextcloud_url,
                username=args.username,
                password=args.password,
            )
            track_url = track_url.rstrip("/")
            if not track_url.endswith("/download"):
                track_url += "/download"

            title = meta.get("title") or track_path.stem
            tracks.append({
                "title": title,
                "url": track_url
            })

    album_data = {
        "album_name": album_name or local_dir.name,
        "artist": artist or "Unknown Artist",
        "album_art": cover_url,
        "tracks": tracks
    }

    print("Generating base64 encoded album JSON...", file=sys.stderr)
    json_str = json.dumps(album_data, indent=2, ensure_ascii=False)
    b64_encoded = base64.b64encode(json_str.encode("utf-8")).decode("utf-8")
    print(f"https://audio.pinapelz.com/?data={b64_encoded}")


if __name__ == "__main__":
    main()
