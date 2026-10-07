#!/usr/bin/env python3

import argparse
import base64
import mimetypes
import re
from pathlib import Path


# ============================================================
# Utility functions
# ============================================================

def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def file_to_data_uri(path: Path) -> str:

    mime_type, _ = mimetypes.guess_type(str(path))

    if mime_type is None:
        mime_type = "application/octet-stream"

    data = base64.b64encode(
        path.read_bytes()
    ).decode("ascii")

    return f"data:{mime_type};base64,{data}"


# ============================================================
# Inline CSS
# ============================================================

def inline_css(html: str, target_dir: Path) -> str:

    pattern = re.compile(
        r'<link([^>]+)href=["\']([^"\']+\.css)["\']([^>]*)>',
        re.IGNORECASE,
    )


    def replace(match):

        css_path = match.group(2)


        # Ignore remote files
        if css_path.startswith(
            (
                "http://",
                "https://",
                "data:",
            )
        ):
            return match.group(0)


        local_path = (
            target_dir / css_path
        ).resolve()


        if not local_path.exists():

            print(
                f"WARNING: CSS file not found: {local_path}"
            )

            return match.group(0)


        css = read_text(local_path)


        return (
            "<style>\n"
            + css
            + "\n</style>"
        )


    return pattern.sub(
        replace,
        html,
    )


# ============================================================
# Inline JavaScript
# ============================================================

def inline_js(html: str, target_dir: Path) -> str:

    pattern = re.compile(
        r'<script([^>]+)src=["\']([^"\']+\.js)["\']([^>]*)>\s*</script>',
        re.IGNORECASE,
    )


    def replace(match):

        js_path = match.group(2)


        # Ignore remote scripts
        if js_path.startswith(
            (
                "http://",
                "https://",
                "data:",
            )
        ):
            return match.group(0)


        local_path = (
            target_dir / js_path
        ).resolve()


        if not local_path.exists():

            print(
                f"WARNING: JavaScript file not found: {local_path}"
            )

            return match.group(0)


        js = read_text(local_path)


        return (
            "<script>\n"
            + js
            + "\n</script>"
        )


    return pattern.sub(
        replace,
        html,
    )


# ============================================================
# Inline local images
# ============================================================

def inline_images(html: str, target_dir: Path) -> str:

    pattern = re.compile(
        r'(?P<prefix>(?:src|href)=["\'])'
        r'(?P<path>[^"\']+)'
        r'(?P<suffix>["\'])',
        re.IGNORECASE,
    )


    def replace(match):

        relative_path = match.group("path")


        # Ignore URLs and special references
        if relative_path.startswith(
            (
                "http://",
                "https://",
                "data:",
                "#",
                "mailto:",
                "javascript:",
            )
        ):
            return match.group(0)


        local_path = (
            target_dir / relative_path
        ).resolve()


        if not local_path.exists():

            return match.group(0)


        mime_type, _ = mimetypes.guess_type(
            str(local_path)
        )


        if not mime_type:
            return match.group(0)


        if not mime_type.startswith("image/"):
            return match.group(0)


        return (
            match.group("prefix")
            + file_to_data_uri(local_path)
            + match.group("suffix")
        )


    return pattern.sub(
        replace,
        html,
    )


# ============================================================
# Inline JSON files
# ============================================================

def inline_json_references(
    html: str,
    target_dir: Path,
) -> str:

    for filename in [
        "manifest.json",
        "catalog.json",
    ]:

        json_path = (
            target_dir / filename
        )


        if not json_path.exists():

            print(
                f"WARNING: {filename} not found"
            )

            continue


        encoded = base64.b64encode(
            json_path.read_bytes()
        ).decode("ascii")


        data_uri = (
            "data:application/json;base64,"
            + encoded
        )


        # Replace quoted references.
        html = html.replace(
            f'"{filename}"',
            f'"{data_uri}"',
        )


        html = html.replace(
            f"'{filename}'",
            f"'{data_uri}'",
        )


    return html


# ============================================================
# Remove source map references
# ============================================================

def remove_source_maps(
    html: str,
) -> str:

    html = re.sub(
        r'//#\s*sourceMappingURL=[^\s]+',
        "",
        html,
    )


    html = re.sub(
        r'/\*#\s*sourceMappingURL=[^*]+\*/',
        "",
        html,
    )


    return html


# ============================================================
# Main conversion
# ============================================================

def create_single_file(
    target_dir: Path,
    output_file: Path,
):

    source_file = (
        target_dir / "index.html"
    )


    if not source_file.exists():

        raise FileNotFoundError(
            f"dbt index.html not found: {source_file}"
        )


    print(
        f"Reading dbt documentation: {source_file}"
    )


    html = read_text(
        source_file
    )


    # --------------------------------------------------------
    # Inline CSS
    # --------------------------------------------------------

    print("Inlining CSS...")

    html = inline_css(
        html,
        target_dir,
    )


    # --------------------------------------------------------
    # Inline JavaScript
    # --------------------------------------------------------

    print("Inlining JavaScript...")

    html = inline_js(
        html,
        target_dir,
    )


    # --------------------------------------------------------
    # Inline images
    # --------------------------------------------------------

    print("Inlining images...")

    html = inline_images(
        html,
        target_dir,
    )


    # --------------------------------------------------------
    # Inline manifest/catalog
    # --------------------------------------------------------

    print(
        "Embedding manifest.json and catalog.json..."
    )

    html = inline_json_references(
        html,
        target_dir,
    )


    # --------------------------------------------------------
    # Remove source maps
    # --------------------------------------------------------

    print(
        "Removing source-map references..."
    )

    html = remove_source_maps(
        html
    )


    # --------------------------------------------------------
    # Write output
    # --------------------------------------------------------

    output_file.parent.mkdir(
        parents=True,
        exist_ok=True,
    )


    output_file.write_text(
        html,
        encoding="utf-8",
    )


    print()
    print("========================================")
    print("Single-file documentation created")
    print("========================================")

    print(
        f"Source : {source_file}"
    )

    print(
        f"Output : {output_file}"
    )

    print(
        f"Size   : {output_file.stat().st_size:,} bytes"
    )

    print("========================================")


# ============================================================
# CLI
# ============================================================

def main():

    parser = argparse.ArgumentParser(
        description=(
            "Create a single self-contained "
            "dbt documentation HTML file."
        )
    )


    parser.add_argument(
        "--target-dir",
        required=True,
        help="dbt target directory",
    )


    parser.add_argument(
        "--output-file",
        required=True,
        help="Output HTML file",
    )


    args = parser.parse_args()


    target_dir = Path(
        args.target_dir
    ).resolve()


    output_file = Path(
        args.output_file
    ).resolve()


    if not target_dir.exists():

        raise FileNotFoundError(
            f"Target directory does not exist: {target_dir}"
        )


    create_single_file(
        target_dir,
        output_file,
    )


if __name__ == "__main__":

    main()