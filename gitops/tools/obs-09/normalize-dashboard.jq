def prometheus: {type: "prometheus", uid: "prometheus"};

def metric_target($ref; $expr; $legend): {
  datasource: prometheus,
  expr: $expr,
  interval: "",
  legendFormat: $legend,
  refId: $ref
};

def normalize_string:
  gsub("cluster=\\\"\\$cluster\\\""; "") |
  gsub("\\{[[:space:]]*,[[:space:]]*"; "{") |
  gsub(",[[:space:]]*\\}"; "}") |
  gsub(",[[:space:]]*,"; ",") |
  gsub("machine_cpu_cores\\{\\}"; "kube_node_status_allocatable{resource=\"cpu\",unit=\"core\"}") |
  gsub("machine_memory_bytes\\{\\}"; "kube_node_status_allocatable{resource=\"memory\",unit=\"byte\"}");

walk(
  if type == "object" and (.datasource? | type) == "object" and .datasource.uid == "${datasource}" then
    .datasource.uid = "prometheus"
  elif type == "string" then
    normalize_string
  else
    .
  end
)
| del(.templating.list[] | select(.name == "datasource" or .name == "cluster"))
| .uid = "obs-09-kubernetes-global"
| .editable = false
| .schemaVersion = 41
| .__inputs = []
| .annotations.list = []
| .panels |= map(select(.id != 46 and .id != 50 and .id != 79))
| (.panels[] | select(.id == 52) | .targets) = [
    metric_target("A"; "count(kube_namespace_created)"; "Namespaces"),
    metric_target("B"; "count(kube_pod_info)"; "Pods"),
    metric_target("C"; "count(kube_pod_status_phase{phase=\"Running\"})"; "Running Pods"),
    metric_target("D"; "count(kube_service_info)"; "Services"),
    metric_target("E"; "count(kube_endpoint_info)"; "Endpoints"),
    metric_target("F"; "count(kube_ingress_info)"; "Ingresses"),
    metric_target("G"; "count(kube_deployment_created)"; "Deployments"),
    metric_target("H"; "count(kube_statefulset_created)"; "StatefulSets"),
    metric_target("I"; "count(kube_daemonset_created)"; "DaemonSets"),
    metric_target("J"; "count(kube_replicaset_created)"; "ReplicaSets"),
    metric_target("K"; "count(kube_job_info)"; "Jobs"),
    metric_target("L"; "count(kube_cronjob_info)"; "CronJobs"),
    metric_target("M"; "count(kube_persistentvolume_info)"; "Persistent Volumes"),
    metric_target("N"; "count(kube_persistentvolumeclaim_info)"; "Persistent Volume Claims"),
    metric_target("O"; "count(kube_horizontalpodautoscaler_info)"; "Horizontal Pod Autoscalers"),
    metric_target("P"; "count(kube_networkpolicy_created)"; "Network Policies"),
    metric_target("Q"; "count(kube_resourcequota_created)"; "Resource Quotas"),
    metric_target("R"; "count(kube_node_info)"; "Nodes")
  ]
