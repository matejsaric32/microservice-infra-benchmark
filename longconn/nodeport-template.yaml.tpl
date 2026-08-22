---
# longconn/nodeport-template.yaml.tpl — template only. The .tpl suffix keeps it
# out of `kubectl apply -f longconn/`, which would otherwise choke on __PORT__.
#
# One Service per framework. The long-lived-connection arm (S9/S10) connects
# here directly so that the keep-alive connections terminate on the application
# pod rather than on the NGINX ingress controller: kube-proxy performs DNAT
# only, so the number of connections on the pod equals the k6 VU count.
#
# These Services sit ALONGSIDE the existing ClusterIP Services in frameworks/;
# they do not replace them. S6/S7 keep using the ingress unchanged.
#
# To add a framework: copy this file to nodeport-<framework>.yaml, substitute
# __APP__/__PORT__, and record the port in the README allocation table.
# Allocated: 31090-31097 (see README). Reserved for the image variants that are
# not deployed by default: 31098 quarkus-perf-native-micro,
# 31099 quarkus-perf-native-micro-compressed, 31100 quarkus-perf-distroless,
# 31101 quarkus-reactive-perf-native-micro,
# 31102 quarkus-reactive-perf-native-micro-compressed,
# 31103 quarkus-reactive-perf-distroless.
apiVersion: v1
kind: Service
metadata:
  name: __APP__-direct
  namespace: perf-test
  labels:
    app: __APP__
    longconn: "true"          # kubectl -n perf-test get svc -l longconn=true
spec:
  type: NodePort
  selector:
    app: __APP__              # must match the deployment's pod label
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
      name: http
      nodePort: __PORT__
