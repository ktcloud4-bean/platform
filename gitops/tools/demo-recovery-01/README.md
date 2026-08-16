# DEMO-RECOVERY-01 실행기

immutable SHA 검증 중 또는 main 수렴 뒤 아래 순서만 실행한다.

```bash
gitops/tools/demo-recovery-01/recovery.sh backup
gitops/tools/demo-recovery-01/recovery.sh attack
gitops/tools/demo-recovery-01/recovery.sh restore
gitops/tools/demo-recovery-01/recovery.sh reset
```

`backup`은 합성 marker가 정상인 PVC `demo-recovery-data`의 Pod volume `recovery-data`만 Kopia로 전송한다.
`attack`은 그 PVC의 합성 marker만 훼손하고 portal Deployment를 삭제해 Argo self-heal과
데이터 미복구를 대조한다. `restore`는 `demo-recovery-01-restore` namespace에 빈 동일 규격 PVC와
Pod를 차례로 만들고 PVR로 Kopia 데이터만 주입한다. Restore는 PVR 생성을 위해 PVC·PV 리소스만
허용하지만 Backup에는 PV를 넣지 않아 기존 PV를 복원하거나 바꾸지 않으며, 정상 hash의 HTTP 응답을 확인한다. `reset`은 `DeleteBackupRequest`로 원격 metadata까지 지운 뒤
이 도구가 만든 Backup·Restore·PVB·PVR·namespace를 삭제하고 원본 marker를 정상으로 되돌린다.
