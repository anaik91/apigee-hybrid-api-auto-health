#!/usr/bin/env python

import sys
import argparse
import json
from kubernetes import client, config
from kubernetes.client.rest import ApiException

def get_k8s_service_ip(namespace, service_name):
    """Fetches the ClusterIP of a given Kubernetes service."""
    try:
        core_v1 = client.CoreV1Api()
        print(f"Fetching IP for service '{service_name}' in namespace '{namespace}'...", file=sys.stderr)
        service = core_v1.read_namespaced_service(name=service_name, namespace=namespace)
        if not service.spec.cluster_ip or service.spec.cluster_ip == "None":
            print(f"Error: Service '{service_name}' found, but it has no ClusterIP.", file=sys.stderr)
            return None
        return service.spec.cluster_ip
    except ApiException as e:
        if e.status == 404:
            print(f"Error: Kubernetes service '{service_name}' not found in namespace '{namespace}'.", file=sys.stderr)
        else:
            print(f"Kubernetes API Error: {e.reason}", file=sys.stderr)
        return None

# The get_apigee_routes_from_cluster and parse_apigee_routes functions are the same as before.
def get_apigee_routes_from_cluster(namespace):
    GROUP, VERSION, PLURAL = "apigee.cloud.google.com", "v1alpha2", "apigeeroutes"
    try:
        config.load_incluster_config()
        api = client.CustomObjectsApi()
        print(f"Fetching ApigeeRoutes from namespace '{namespace}'...", file=sys.stderr)
        api_response = api.list_namespaced_custom_object(
            group=GROUP, version=VERSION, namespace=namespace, plural=PLURAL
        )
        return api_response.get("items", [])
    except (config.ConfigException, ApiException) as e:
        print(f"Error connecting to Kubernetes: {e}", file=sys.stderr)
        return None

def parse_apigee_routes(items):
    hostname_map = {}
    if not items: return hostname_map
    for item in items:
        spec = item.get('spec', {})
        hostnames = spec.get('hostnames')
        rules = spec.get('rules', {}).get('http', [])
        if not hostnames or not rules: continue
        routes = []
        for rule in rules:
            for match in rule.get('matches', []):
                uri = match.get('uri', {})
                prefix = uri.get('prefixPattern') or uri.get('prefix')
                if prefix and not prefix.startswith('/__apigee__/'):
                    routes.append(prefix)
        if routes:
            for hostname in hostnames:
                hostname_map.setdefault(hostname, [])
                for route in routes:
                    if route not in hostname_map[hostname]:
                        hostname_map[hostname].append(route)
    return hostname_map

def generate_prometheus_targets(route_map, service_ip):
    """Generates Prometheus targets using the service IP instead of the hostname."""
    targets = []
    for hostname, routes in route_map.items():
        for route in routes:
            # The target URL now uses the IP address.
            probe_url = f"https://{service_ip}/healthz{route}"
            
            targets.append({
                "targets": [probe_url],
                "labels": {
                    "apigee_hostname": hostname, # This label is now CRITICAL
                    "apigee_basepath": route,
                    "job": "apigee-health"
                }
            })
    return targets

def main():
    parser = argparse.ArgumentParser(
        description="Generate a Prometheus target file for Apigee health checks using a K8s Service IP."
    )
    parser.add_argument(
        "-n", "--namespace",
        default="apigee",
        help="The Kubernetes namespace where Apigee is installed."
    )
    parser.add_argument(
        "-s", "--service-name",
        required=True,
        help="The name of the Apigee ingress Kubernetes service (e.g., 'apigee-ingressgateway-test1-svc')."
    )
    parser.add_argument(
        "-o", "--outfile",
        default="apigee_targets.json",
        help="The output file path for the Prometheus targets."
    )
    args = parser.parse_args()

    # Load K8s config first
    try:
        config.load_incluster_config()
    except config.ConfigException as e:
        print(f"Error loading kubeconfig: {e}", file=sys.stderr)
        sys.exit(1)

    # 1. Get the Service IP
    service_ip = get_k8s_service_ip(args.namespace, args.service_name)
    if not service_ip:
        sys.exit(1)
    print(f"Found service IP: {service_ip}", file=sys.stderr)

    # 2. Fetch and parse Apigee routes
    items = get_apigee_routes_from_cluster(args.namespace)
    if items is None:
        sys.exit(1)
    route_map = parse_apigee_routes(items)
    if not route_map:
        print("No valid Apigee routes found.", file=sys.stderr)
        with open(args.outfile, 'w') as f: json.dump([], f)
        return

    # 3. Generate targets using the IP
    prometheus_targets = generate_prometheus_targets(route_map, service_ip)

    # 4. Write to file
    with open(args.outfile, 'w') as f:
        json.dump(prometheus_targets, f, indent=2)
    print(f"Successfully wrote {len(prometheus_targets)} targets to {args.outfile}", file=sys.stderr)

if __name__ == "__main__":
    main()