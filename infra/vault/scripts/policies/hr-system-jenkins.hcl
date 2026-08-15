# QUALITY-05 Jenkins reads only the dedicated HR System Sonar project token.
path "kv/data/hr-system/jenkins" {
  capabilities = ["read"]
}

path "kv/metadata/hr-system/jenkins" {
  capabilities = ["read"]
}
