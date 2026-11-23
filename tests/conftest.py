"""Shared pytest fixtures: a YAML loader that understands CloudFormation intrinsic tags."""
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
TEMPLATE_PATH = REPO_ROOT / "infra" / "eks-webapp.yaml"

# Short-form tag -> CloudFormation long-form key.
_TAGS = {
    "Ref": "Ref",
    "Sub": "Fn::Sub",
    "GetAtt": "Fn::GetAtt",
    "If": "Fn::If",
    "Select": "Fn::Select",
    "Split": "Fn::Split",
    "FindInMap": "Fn::FindInMap",
    "Join": "Fn::Join",
    "Cidr": "Fn::Cidr",
    "GetAZs": "Fn::GetAZs",
    "Equals": "Fn::Equals",
    "Not": "Fn::Not",
    "And": "Fn::And",
    "Or": "Fn::Or",
    "Condition": "Condition",
    "ImportValue": "Fn::ImportValue",
    "Base64": "Fn::Base64",
}


class CfnLoader(yaml.SafeLoader):
    """SafeLoader with CloudFormation intrinsic function tags."""


def _construct(tag_name, key):
    def constructor(loader, node):
        if isinstance(node, yaml.ScalarNode):
            value = loader.construct_scalar(node)
            # !GetAtt A.B is equivalent to Fn::GetAtt: [A, B]
            if key == "Fn::GetAtt" and isinstance(value, str):
                value = value.split(".", 1)
        elif isinstance(node, yaml.SequenceNode):
            value = loader.construct_sequence(node, deep=True)
        else:
            value = loader.construct_mapping(node, deep=True)
        return {key: value}

    return constructor


for _name, _key in _TAGS.items():
    CfnLoader.add_constructor(f"!{_name}", _construct(_name, _key))


def load_template(path=TEMPLATE_PATH):
    with open(path, "r", encoding="utf-8") as f:
        return yaml.load(f, Loader=CfnLoader)


@pytest.fixture(scope="session")
def template_path():
    return TEMPLATE_PATH


@pytest.fixture(scope="session")
def load_yaml():
    """Return a function that loads a CloudFormation YAML file into a dict."""
    return load_template


@pytest.fixture(scope="session")
def template():
    """The parsed infra/eks-webapp.yaml template."""
    return load_template()
