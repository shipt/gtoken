module github.com/doitintl/gtoken-webhook

go 1.13

require (
	github.com/google/go-cmp v0.5.2
	github.com/prometheus/client_golang v1.3.0
	github.com/sirupsen/logrus v1.4.2
	github.com/slok/kubewebhook v0.3.0
	github.com/urfave/cli v1.22.2
	k8s.io/api v0.20.0
	k8s.io/apimachinery v0.20.0
	k8s.io/client-go v0.20.0
	k8s.io/klog v1.0.0 // indirect
	sigs.k8s.io/controller-runtime v0.4.0
)

replace golang.org/x/oauth2 => golang.org/x/oauth2 v0.0.0-20180821212333-d2e6202438be
