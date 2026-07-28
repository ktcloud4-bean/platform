#!/usr/bin/env python3
"""OPNsense config.xml 을 커밋 가능한 형태로 정규화한다.

두 가지 일을 한다.

1. **노이즈 제거** — <revision> 은 설정을 저장할 때마다 타임스탬프가 바뀐다.
   지우지 않으면 실제 변경이 없어도 매일 diff 가 발생해 알림이 무의미해진다.

2. **시크릿 마스킹** — config.xml 에는 비밀번호 해시 · TLS 개인키 · API 키가
   평문으로 들어 있다. 그대로 커밋하면 안 된다.

사용법 (저장소 루트 기준):
    python3 infra/opnsense/scripts/normalize.py infra/opnsense/config.raw.xml \
        -o infra/opnsense/config.xml
"""
import argparse
import sys
import xml.etree.ElementTree as ET

# 값을 통째로 가릴 태그. 하위 요소가 아니라 이 태그의 텍스트가 대상이다.
SECRET_TAGS = {
    "password",          # 사용자 비밀번호 해시
    "otp_seed",          # TOTP 시드 — 이게 유출되면 2FA 가 무의미해진다
    "prv",               # 인증서 개인키
    "privatekey",
    "private-key",
    "apikeys",           # API 키 묶음
    "apikey",
    "secret",
    "pre-shared-key",
    "presharedkey",
    "sharedkey",
    "tunnelpassword",
    "passwd",
    "md5-hash",
    "bcrypt_hash",
    "radius_secret",
    "ldap_bindpw",
}

# os-acme-client 의 DNS-01 validation 은 공급자별 자격증명을 dns_* 태그에
# 저장한다. 공급자가 추가돼도 token/key 이름을 하나씩 놓치지 않도록,
# 자격증명에 사용하는 접미사를 함께 검사한다. zone_id/account_id 같은
# 비밀이 아닌 식별자는 이 규칙에 해당하지 않아 diff 에 남는다.
ACME_DNS_SECRET_SUFFIXES = (
    "token",
    "secret",
    "password",
    "passwd",
    "_pass",
    "_pw",
    "_key",
    "apikey",
    "_credentials",
)

# 통째로 제거할 태그. 내용이 매번 바뀌어 diff 노이즈만 만든다.
DROP_TAGS = {
    "revision",          # 저장 시각 · 변경자 IP · 변경 페이지
}

MASK = "***MASKED***"


def is_secret_tag(tag: str) -> bool:
    """태그가 일반 또는 ACME DNS provider 자격증명인지 판단한다."""
    normalized = tag.casefold()
    if normalized in SECRET_TAGS:
        return True
    return normalized.startswith("dns_") and normalized.endswith(
        ACME_DNS_SECRET_SUFFIXES
    )


def scrub(elem: ET.Element) -> None:
    """트리를 순회하며 시크릿을 가리고 노이즈 태그를 제거한다."""
    for child in list(elem):
        if child.tag in DROP_TAGS:
            elem.remove(child)
            continue
        if is_secret_tag(child.tag):
            # 원래 값이 있었는지 여부는 유지한다.
            # 빈 태그를 마스킹하면 "값이 생겼다"는 거짓 diff 가 난다.
            if child.text and child.text.strip():
                child.text = MASK
            for gc in list(child):
                child.remove(gc)
            continue
        scrub(child)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("infile", help="OPNsense 에서 내려받은 원본 config.xml")
    ap.add_argument("-o", "--outfile", help="출력 파일 (기본: 표준출력)")
    args = ap.parse_args()

    try:
        tree = ET.parse(args.infile)
    except ET.ParseError as e:
        print(f"XML 파싱 실패: {e}", file=sys.stderr)
        return 1

    root = tree.getroot()
    scrub(root)

    # 들여쓰기를 고정해 포맷 차이로 인한 diff 를 없앤다.
    ET.indent(tree, space="  ")

    out = ET.tostring(root, encoding="unicode")
    if not out.endswith("\n"):
        out += "\n"

    if args.outfile:
        with open(args.outfile, "w", encoding="utf-8") as f:
            f.write(out)
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
