#!/usr/bin/env python3

import argparse
import base64
import mimetypes
import re
from pathlib import Path


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def make_data_uri(path: Path) -> str:
    mime_type, _ = mimetypes.guess_type(path.name)

    if mime_type is None:
        mime_type = "application/octet-stream"

    encoded = base64.b64encode(path.read_bytes()).decode("ascii")

    return f"data:{mime_type};base64,{encoded}"


def inline_css(html: str, target_dir: Path) -> str:

    pattern = re.compile(
        r'<link([^>]+)href=["\']([^"\']+\.css)["\']([^>]*)>',
        re.IGNORECASE,
    )

    def replace(match):

        href = match.group(2)

        if "://" in href or href.startswith("data:"):
            return match.group(0)

        css_path = target_dir / href

        if not css_path.exists():
            print(f"WARNING: CSS file not found: {css_path}")
            return match.group(0)

        css = read_text(css_path)

        return f"<style>\n{css}\n</style>"

    return pattern.sub(replace, html)


def inline_js(html: str, target_dir: Path) -> str:

    pattern = re.compile(
        r'<script([^>]*)src=["\']([^"\']+\.js)["\']([^>]*)></script>',
        re.IGNORECASE,
    )

    def replace(match):

        prefix = match.group(1)
        src = match.group(2)
        suffix = match.group(3)

        if "://" in src or src.startswith("data:"):
            return match.group(0)

        js_path = target_dir / src

        if not js_path.exists():
            print(f"WARNING: JavaScript file not found: {js_path}")
            return match.group(0)

        js = read_text(js_path)

        return (
            f"<script{prefix}{suffix}>\n"
            f"{js}\n"
            f"</script>"
        )

    return pattern.sub(replace, html)


def inline_images(html: str, target_dir: Path) -> str:

    # src="image.png"
    src_pattern = re.compile(
        r'(?P<prefix>\b(?:src|href)=["\'])(?P<path>[^"\']+)(?P<suffix>["\'])',
        re.IGNORECASE,
    )

    def replace(match):

        relative_path = match.group("path")

        if (
            relative_path.startswith("data:")
            or relative_path.startswith("http://")
            or relative_path.startswith("https://")
            or relative_path.startswith("#")
            or relative_path.startswith("mailto:")
        ):
            return match.group(0)

        file_path = target_dir / relative_path

        if not file_path.exists() or not file_path.is_file():
            return match.group(0)

        mime_type, _ = mimetypes.guess_type(file_path.name)

        if not mime_type or not mime_type.startswith("image/"):
            return match.group(0)

        data_uri = make_data_uri(file_path)

        return (
            match.group("prefix")
            + data_uri
            + match.group("suffix")
        )

    return src_pattern.sub(replace, html)


def inline_json_references(html: str, target_dir: Path) -> str:

    for filename in ["manifest.json", "catalog.json"]:

        json_path = target_dir / filename

        if not json_path.exists():
            print(f"WARNING: {filename} not found.")
            continue

        json_data = json_path.read_bytes()

        encoded = base64.b64encode(json_data).decode("ascii")

        data_uri = (
            f"data:application/json;base64,{encoded}"
        )

        # Replace references such as:
        #
        # "manifest.json"
        # 'manifest.json'
        #
        escaped = re.escape(filename)

        html = re.sub(
            rf'(["\']){escaped}\1',
            lambda match: f'"{data_uri}"',
            html,
        )

        print(f"Inlined {filename}")

    return html


def remove_source_maps(html: str) -> str:

    html = re.sub(
        r'/\*# sourceMappingURL=.*?\*/',
        "",
        html,
        flags=re.DOTALL,
    )

    html = re.sub(
        r'//# sourceMappingURL=.*?$',
        "",
        html,
        flags=re.MULTILINE,
    )

    return html


def create_single_file(
    target_dir: Path,
    output_file: Path,
) -> None:

    source_html = target_dir / "index.html"

    if not source_html.exists():
        raise FileNotFoundError(
            f"dbt docs index.html not found: {source_html}"
        )

    print("Reading dbt docs:")
    print(source_html)

    html = read_text(source_html)

    print("Inlining CSS...")
    html = inline_css(html, target_dir)

    print("Inlining JavaScript...")
    html = inline_js(html, target_dir)

    print("Inlining images...")
    html = inline_images(html, target_dir)

    print("Embedding manifest.json and catalog.json...")
    html = inline_json_references(html, target_dir)

    print("Removing source-map references...")
    html = remove_source_maps(html)

    output_file.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    output_file.write_text(
        html,
        encoding="utf-8",
    )

    print("------------------------------------------")
    print("Single-file dbt docs created")
    print("------------------------------------------")
    print(f"Output : {output_file}")
    print(f"Size   : {output_file.stat().st_size} bytes")


def main():

    parser = argparse.ArgumentParser(
        description="Create a self-contained single-file dbt docs HTML."
    )

    parser.add_argument(
        "--target-dir",
        required=True,
        help="dbt target directory",
    )

    parser.add_argument(
        "--output-file",
        required=True,
        help="Output single HTML file",
    )

    args = parser.parse_args()

    target_dir = Path(args.target_dir).resolve()
    output_file = Path(args.output_file).resolve()

    create_single_file(
        target_dir,
        output_file,
    )


if __name__ == "__main__":
    main()