```bash
kubectl delete pods --all -n perf-test --force --grace-period=0
```

```bash
kubectl delete namespace perf-test --force --grace-period=0
```

```bash
sudo bash setup-cluster.sh
```

```bash
sudo systemctl restart k3s
```

```bash
sudo /usr/local/bin/k3s-uninstall.sh

# Clean up any leftover data
sudo rm -rf /etc/rancher/k3s
sudo rm -rf /var/lib/rancher/k3s

# Fresh install
curl -sfL https://get.k3s.io | sh -
```