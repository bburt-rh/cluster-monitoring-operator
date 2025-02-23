local alertmanager = import 'github.com/prometheus-operator/kube-prometheus/jsonnet/kube-prometheus/components/alertmanager.libsonnet';
// TODO: replace current addition of kube-rbac-proxy with upstream lib
// local krp = import 'github.com/prometheus-operator/kube-prometheus/jsonnet/kube-prometheus/components/kube-rbac-proxy.libsonnet';
local generateCertInjection = import '../utils/generate-certificate-injection.libsonnet';
local generateSecret = import '../utils/generate-secret.libsonnet';
local withDescription = (import '../utils/add-annotations.libsonnet').withDescription;
local requiredRoles = (import '../utils/add-annotations.libsonnet').requiredRoles;
local requiredClusterRoles = (import '../utils/add-annotations.libsonnet').requiredClusterRoles;

function(params)
  local cfg = params {
    replicas: 2,
  };

  alertmanager(cfg) {
    trustedCaBundle: generateCertInjection.trustedCNOCaBundleCM(cfg.namespace, 'alertmanager-trusted-ca-bundle'),

    // OpenShift route to access the Alertmanager UI.

    route: {
      apiVersion: 'v1',
      kind: 'Route',
      metadata: {
        name: 'alertmanager-main',
        namespace: cfg.namespace,
        annotations: withDescription(
          'Expose the `/api` endpoints of the `alertmanager-main` service via a router.',
        ),
      },
      spec: {
        path: '/api',
        to: {
          kind: 'Service',
          name: 'alertmanager-main',
        },
        port: {
          targetPort: 'web',
        },
        tls: {
          termination: 'Reencrypt',
          insecureEdgeTerminationPolicy: 'Redirect',
        },
      },
    },

    // The ServiceAccount needs this annotation, to signify the identity
    // provider, that when a users it doing the oauth flow through the oauth
    // proxy, that it should redirect to the alertmanager-main route on
    // successful authentication.
    serviceAccount+: {
      metadata+: {
        annotations+: {
          'serviceaccounts.openshift.io/oauth-redirectreference.alertmanager-main': '{"kind":"OAuthRedirectReference","apiVersion":"v1","reference":{"kind":"Route","name":"alertmanager-main"}}',
        },
      },
      // Alertmanager can mount the token into the pod since
      // https://github.com/prometheus-operator/prometheus-operator/pull/5474
      // and v0.66.0
      automountServiceAccountToken: false,
    },

    // Adding the serving certs annotation causes the serving certs controller
    // to generate a valid and signed serving certificate and put it in the
    // specified secret.
    //
    // The ClusterIP is explicitly set, as it signifies the
    // cluster-monitoring-operator, that when reconciling this service the
    // cluster IP needs to be retained.
    //
    // The ports are overridden, as due to the port binding of the oauth proxy
    // the serving port is 9094 instead of the 9093 default.

    service+: {
      metadata+: {
        annotations: {
          'service.beta.openshift.io/serving-cert-secret-name': 'alertmanager-main-tls',
        } + withDescription(
          |||
            Expose the Alertmanager web server within the cluster on the following ports:
            * Port %d provides access to all the Alertmanager endpoints. %s
            * Port %d provides access to the Alertmanager endpoints restricted to a given project. %s
            * Port %d provides access to the `/metrics` endpoint only. This port is for internal use, and no other usage is guaranteed.
          ||| % [
            $.service.spec.ports[0].port,
            requiredRoles(['monitoring-alertmanager-edit'], 'openshift-monitoring'),
            $.service.spec.ports[1].port,
            requiredClusterRoles(['monitoring-rules-edit', 'monitoring-edit'], false, ''),
            $.service.spec.ports[2].port,
          ],
        ),
      },
      spec+: {
        ports: [
          {
            name: 'web',
            port: 9094,
            targetPort: 'web',
          },
          {
            name: 'tenancy',
            port: 9092,
            targetPort: 'tenancy',
          },
          {
            name: 'metrics',
            port: 9097,
            targetPort: 'metrics',
          },
        ],
        type: 'ClusterIP',
      },
    },

    // The proxy secret is there to encrypt session created by the oauth proxy.
    proxySecret: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: {
        name: 'alertmanager-main-proxy',
        namespace: cfg.namespace,
        labels: { 'app.kubernetes.io/name': 'alertmanager-main' },
      },
      type: 'Opaque',
      data: {},
    },

    // In order for the oauth proxy to perform a TokenReview and
    // SubjectAccessReview for authN and authZ the alertmanager ServiceAccount
    // requires the `create` action on both of these.

    clusterRole: {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'ClusterRole',
      metadata: {
        name: 'alertmanager-main',
      },
      rules: [
        {
          apiGroups: ['authentication.k8s.io'],
          resources: ['tokenreviews'],
          verbs: ['create'],
        },
        {
          apiGroups: ['authorization.k8s.io'],
          resources: ['subjectaccessreviews'],
          verbs: ['create'],
        },
        {
          // By default authenticated service accounts are assigned to the `restricted` SCC which implies MustRunAsRange.
          // This is problematic with statefulsets as UIDs (and file permissions) can change if SCCs are elevated.
          // Instead, this sets the `nonroot` SCC in conjunction with a static fsGroup and runAsUser security context below
          // to be immune against UID changes.
          apiGroups: ['security.openshift.io'],
          resources: ['securitycontextconstraints'],
          resourceNames: ['nonroot'],
          verbs: ['use'],
        },
      ],
    },

    clusterRoleBinding: {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'ClusterRoleBinding',
      metadata: {
        name: 'alertmanager-main',
      },
      roleRef: {
        apiGroup: 'rbac.authorization.k8s.io',
        kind: 'ClusterRole',
        name: 'alertmanager-main',
      },
      subjects: [{
        kind: 'ServiceAccount',
        name: 'alertmanager-main',
        namespace: cfg.namespace,
      }],
    },

    kubeRbacProxySecret: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: {
        name: 'alertmanager-kube-rbac-proxy',
        namespace: cfg.namespace,
        labels: { 'app.kubernetes.io/name': 'alertmanager-main' },
      },
      type: 'Opaque',
      stringData: {
        'config.yaml': std.manifestYamlDoc({
          authorization: {
            rewrites: {
              byQueryParameter: {
                name: 'namespace',
              },
            },
            resourceAttributes: {
              apiGroup: 'monitoring.coreos.com',
              resource: 'prometheusrules',
              namespace: '{{ .Value }}',
            },
          },
        }),
      },
    },

    kubeRbacProxyMetricSecret: generateSecret.staticAuthSecret(cfg.namespace, cfg.commonLabels, 'alertmanager-kube-rbac-proxy-metric') + {
      metadata+: {
        labels: { 'app.kubernetes.io/name': 'alertmanager-main' },
      },
    },

    // This changes the alertmanager to be scraped with TLS, authN and authZ,
    // which are not present in kube-prometheus.
    serviceMonitor+: {
      spec+: {
        endpoints: [
          {
            port: 'metrics',
            interval: '30s',
            scheme: 'https',
            tlsConfig: {
              caFile: '/etc/prometheus/configmaps/serving-certs-ca-bundle/service-ca.crt',
              certFile: '/etc/prometheus/secrets/metrics-client-certs/tls.crt',
              keyFile: '/etc/prometheus/secrets/metrics-client-certs/tls.key',
            },
          },
        ],
      },
    },

    // These patches inject the oauth proxy as a sidecar and configures it with
    // TLS.
    alertmanager+: {
      spec+: {
        securityContext: {
          fsGroup: 65534,
          runAsNonRoot: true,
          runAsUser: 65534,
        },
        priorityClassName: 'system-cluster-critical',
        web: {
          httpConfig: {
            headers: {
              contentSecurityPolicy: "frame-ancestors 'none'",
            },
          },
        },
        secrets: [
          'alertmanager-main-tls',
          'alertmanager-main-proxy',
          $.kubeRbacProxySecret.metadata.name,
          $.kubeRbacProxyMetricSecret.metadata.name,
        ],
        listenLocal: true,
        resources: {
          requests: {
            cpu: '4m',
            memory: '40Mi',
          },
        },
        automountServiceAccountToken: true,
        containers: [
          {
            name: 'alertmanager-proxy',
            image: 'quay.io/openshift/oauth-proxy:latest',  //FIXME(paulfantom)
            ports: [
              {
                containerPort: 9095,
                name: 'web',
              },
            ],
            env: [
              {
                name: 'HTTP_PROXY',
                value: '',
              },
              {
                name: 'HTTPS_PROXY',
                value: '',
              },
              {
                name: 'NO_PROXY',
                value: '',
              },
            ],
            args: [
              '-provider=openshift',
              '-https-address=:9095',
              '-http-address=',
              '-email-domain=*',
              '-upstream=http://localhost:9093',
              '-openshift-sar=[{"resource": "namespaces", "verb": "get"}, {"resource": "alertmanagers", "resourceAPIGroup": "monitoring.coreos.com", "namespace": "openshift-monitoring", "verb": "patch", "resourceName": "non-existant"}]',
              '-openshift-delegate-urls={"/": {"resource": "namespaces", "verb": "get"}, "/": {"resource":"alertmanagers", "group": "monitoring.coreos.com", "namespace": "openshift-monitoring", "verb": "patch", "name": "non-existant"}}',
              '-tls-cert=/etc/tls/private/tls.crt',
              '-tls-key=/etc/tls/private/tls.key',
              '-client-secret-file=/var/run/secrets/kubernetes.io/serviceaccount/token',
              '-cookie-secret-file=/etc/proxy/secrets/session_secret',
              '-openshift-service-account=alertmanager-main',
              '-openshift-ca=/etc/pki/tls/cert.pem',
              '-openshift-ca=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt',
            ],
            resources: {
              requests: {
                cpu: '1m',
                memory: '20Mi',
              },
            },
            volumeMounts: [
              {
                mountPath: '/etc/tls/private',
                name: 'secret-alertmanager-main-tls',
              },
              {
                mountPath: '/etc/proxy/secrets',
                name: 'secret-alertmanager-main-proxy',
              },
            ],
          },
          {
            name: 'kube-rbac-proxy',
            image: cfg.kubeRbacProxyImage,
            resources: {
              requests: {
                cpu: '1m',
                memory: '15Mi',
              },
            },
            ports: [
              {
                containerPort: 9092,
                name: 'tenancy',
              },
            ],
            args: [
              '--secure-listen-address=0.0.0.0:9092',
              '--upstream=http://127.0.0.1:9096',
              '--config-file=/etc/kube-rbac-proxy/config.yaml',
              '--tls-cert-file=/etc/tls/private/tls.crt',
              '--tls-private-key-file=/etc/tls/private/tls.key',
              '--tls-cipher-suites=' + cfg.tlsCipherSuites,
            ],
            volumeMounts: [
              {
                mountPath: '/etc/kube-rbac-proxy',
                name: 'secret-' + $.kubeRbacProxySecret.metadata.name,
              },
              {
                mountPath: '/etc/tls/private',
                name: 'secret-alertmanager-main-tls',
              },
            ],
          },
          {
            // TODO: merge this metric proxy with tenancy proxy when the issue below is fixed:
            // https://github.com/brancz/kube-rbac-proxy/issues/146
            name: 'kube-rbac-proxy-metric',
            image: cfg.kubeRbacProxyImage,
            resources: {
              requests: {
                cpu: '1m',
                memory: '15Mi',
              },
            },
            ports: [
              {
                containerPort: 9097,
                name: 'metrics',
              },
            ],
            args: [
              '--secure-listen-address=0.0.0.0:9097',
              '--upstream=http://127.0.0.1:9093',
              '--config-file=/etc/kube-rbac-proxy/config.yaml',
              '--tls-cert-file=/etc/tls/private/tls.crt',
              '--tls-private-key-file=/etc/tls/private/tls.key',
              '--tls-cipher-suites=' + cfg.tlsCipherSuites,
              '--client-ca-file=/etc/tls/client/client-ca.crt',
              '--logtostderr=true',
              '--allow-paths=/metrics',
            ],
            volumeMounts: [
              {
                mountPath: '/etc/kube-rbac-proxy',
                name: 'secret-' + $.kubeRbacProxyMetricSecret.metadata.name,
                readOnly: true,
              },
              {
                mountPath: '/etc/tls/private',
                name: 'secret-alertmanager-main-tls',
                readOnly: true,
              },
              {
                mountPath: '/etc/tls/client',
                name: 'metrics-client-ca',
                readOnly: true,
              },
            ],
          },
          {
            name: 'prom-label-proxy',
            image: cfg.promLabelProxyImage,
            args: [
              '--insecure-listen-address=127.0.0.1:9096',
              '--upstream=http://127.0.0.1:9093',
              '--label=namespace',
              '--error-on-replace',
            ],
            resources: {
              requests: {
                cpu: '1m',
                memory: '20Mi',
              },
            },
          },
        ],
        volumes+: [
          {
            name: 'metrics-client-ca',
            configMap: {
              name: 'metrics-client-ca',
            },
          },
        ],
      },
    },
  }
