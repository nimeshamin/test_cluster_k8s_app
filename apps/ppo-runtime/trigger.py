"""Submit a PPO training run by creating an Argo Workflow that references the
`ppo-training` WorkflowTemplate (deployed by the sibling Helm chart).

Designed to be invoked from a local shell or a GitHub Action after image builds:

    python trigger.py --worker-tag $WORKER_SHA --trainer-tag $TRAINER_SHA

The script uses the local kubeconfig (no port-forward required); for remote
clusters set KUBECONFIG before running.
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone

from kubernetes import client, config


WORKFLOW_GROUP = "argoproj.io"
WORKFLOW_VERSION = "v1alpha1"
WORKFLOW_PLURAL = "workflows"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker-tag", required=True, help="agi-rl-rl-worker image tag")
    parser.add_argument("--trainer-tag", required=True, help="agi-rl-rl-trainer image tag")
    parser.add_argument(
        "--namespace",
        default="kubeflow",
        help="Namespace the WorkflowTemplate lives in (default: %(default)s).",
    )
    parser.add_argument(
        "--template-name",
        default="ppo-training",
        help="WorkflowTemplate name (default: %(default)s).",
    )
    parser.add_argument(
        "--mlflow-uri",
        default="http://mlflow.mlflow.svc.cluster.local:5000",
        help="MLflow tracking URI passed to containers as MLFLOW_TRACKING_URI.",
    )
    parser.add_argument(
        "--experiment",
        default="ppo-default",
        help="MLflow experiment name.",
    )
    args = parser.parse_args()

    try:
        config.load_kube_config()
    except config.ConfigException:
        config.load_incluster_config()

    body = {
        "apiVersion": f"{WORKFLOW_GROUP}/{WORKFLOW_VERSION}",
        "kind": "Workflow",
        "metadata": {
            "generateName": f"{args.template_name}-",
            "namespace": args.namespace,
            "labels": {
                "app.kubernetes.io/part-of": "ppo-training",
                "ppo-runtime/trigger": "manual",
            },
        },
        "spec": {
            "workflowTemplateRef": {"name": args.template_name},
            "arguments": {
                "parameters": [
                    {"name": "worker-image-tag", "value": args.worker_tag},
                    {"name": "trainer-image-tag", "value": args.trainer_tag},
                    {"name": "mlflow-tracking-uri", "value": args.mlflow_uri},
                    {"name": "experiment-name", "value": args.experiment},
                ]
            },
        },
    }

    api = client.CustomObjectsApi()
    created = api.create_namespaced_custom_object(
        group=WORKFLOW_GROUP,
        version=WORKFLOW_VERSION,
        namespace=args.namespace,
        plural=WORKFLOW_PLURAL,
        body=body,
    )
    name = created["metadata"]["name"]
    started_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    print(f"[trigger] created workflow {args.namespace}/{name} at {started_at}")
    print(f"[trigger] worker={args.worker_tag} trainer={args.trainer_tag}")
    print(f"[trigger] follow with: kubectl -n {args.namespace} get workflow {name} -w")
    print(f"[trigger] logs: kubectl -n {args.namespace} logs -l workflows.argoproj.io/workflow={name} -c main --tail=-1 -f")
    return 0


if __name__ == "__main__":
    sys.exit(main())
