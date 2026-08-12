walk(
  if type == "object" and (.datasource? | type) == "object" and .datasource.uid == "${ds_prometheus}" then
    .datasource.uid = "prometheus"
  else
    .
  end
)
| del(.templating.list[] | select(.name == "ds_prometheus"))
| .uid = "obs-11-node-exporter-full"
| .editable = false
| .schemaVersion = 41
| .__inputs = []
| .annotations.list = []
# processes collector 미확대(OBS-11 canary 판정, infra/ansible/roles/node_exporter_baseline/defaults/main.yml)로
# node_processes_* 시계열이 node_exporter 자기 프로세스 1개만 반영해 제거하는 panel.
| (.panels[].panels?) |= (if . == null then . else map(select(.id != 315 and .id != 313 and .id != 314)) end)
| .panels |= map(select(.id != 315 and .id != 313 and .id != 314))
