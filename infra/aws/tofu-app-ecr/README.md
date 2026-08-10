# 애플리케이션 ECR 레지스트리 계층 · OpenTofu

이 root는 frontend·backend ECR repository를 소유한다. 둘 다 push 시 scan을 켜고 immutable
tag를 사용한다. 기존 tag 덮어쓰기와 repository force delete는 허용하지 않는다.

Jenkins는 `init`·`validate`·`plan`만 실행한다. 최초 생성은 검토된 plan과 명시 승인 뒤
administrator가 같은 `v1` backend에서 수행한다.
