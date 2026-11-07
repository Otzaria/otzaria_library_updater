"""Prepare and verify bounded-memory split fixtures outside the AOT process."""
import argparse
import hashlib
import json
from pathlib import Path


def sha_file(file):
    digest = hashlib.sha256()
    with Path(file).open("rb") as reader:
        while chunk := reader.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def prepare(directory, mib):
    directory.mkdir(parents=True, exist_ok=False)
    size = mib << 20
    destination = directory / "archive.zst"
    token = "independent-qa-v1"
    # Unequal, non-aligned boundaries exercise short final reads in each part.
    sizes = [size // 3, size // 3 + 17, size - 2 * (size // 3) - 17]
    chunk = bytes((i * 31 + (i >> 9)) & 255 for i in range(1 << 16))
    whole = hashlib.sha256()
    parts = []
    for i, length in enumerate(sizes):
        name = f"archive.zst.part-{i:03d}"
        part_path = Path(f"{destination}.part-{i:03d}")
        digest = hashlib.sha256()
        remaining = length
        with part_path.open("wb") as writer:
            while remaining:
                data = chunk[:min(remaining, len(chunk))]
                writer.write(data)
                digest.update(data)
                whole.update(data)
                remaining -= len(data)
        digest_hex = digest.hexdigest()
        Path(f"{part_path}.resume").write_text(f"{token}|{name}|{digest_hex}")
        parts.append({"name": name, "size": length, "sha256": digest_hex,
                      "path": str(part_path)})
    metadata = {"archive": "archive.zst", "size": size,
                "sha256": whole.hexdigest(), "destination": str(destination),
                "source_sha256": sha_file(Path(__file__).resolve().parents[1] /
                    "lib/src/services/patch_downloader.dart"),
                "token": token, "parts": parts}
    path = directory / "manifest.json"
    path.write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps({"prepared": str(path), "bytes": size, "parts": sizes}))


def verify(path, mode):
    metadata = json.loads(path.read_text())
    destination = Path(metadata["destination"])
    assert not Path(f"{destination}.joining").exists()
    if mode == "cancel":
        assert not destination.exists()
        for part in metadata["parts"]:
            assert Path(part["path"]).stat().st_size == part["size"]
            assert sha_file(part["path"]) == part["sha256"]
            assert Path(f'{part["path"]}.resume').read_text().splitlines()[0] == (
                f'{metadata["token"]}|{part["name"]}|{part["sha256"]}')
    else:
        assert destination.stat().st_size == metadata["size"]
        assert sha_file(destination) == metadata["sha256"]
        assert Path(f"{destination}.resume").read_text().splitlines()[0] == (
            f'{metadata["token"]}|joined:{metadata["sha256"]}')
        for part in metadata["parts"]:
            assert not Path(part["path"]).exists()
            assert not Path(f'{part["path"]}.resume').exists()
    print(json.dumps({"verified": mode, "size": metadata["size"],
                      "sha256": metadata["sha256"]}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["prepare", "cancel", "retry"])
    parser.add_argument("path", type=Path)
    parser.add_argument("mib", type=int, nargs="?")
    args = parser.parse_args()
    if args.mode == "prepare":
        prepare(args.path, args.mib)
    else:
        verify(args.path, args.mode)
