#!/usr/bin/env python3
"""
ssm_preflight.py — Pre-deploy SSM validation and auto-provisioning.

Runs on the GitHub Actions runner BEFORE any deployment.

For each placeholder in cicd.config.yml secrets_map:
  1. Build full SSM path: /{ssm_prefix}/{relative_path}
  2. Check SSM — exists and non-empty → ready
  3. Missing in SSM → check GitHub Secrets (via SECRETS_JSON env var)
  4. Found in secrets → auto-provision SSM
  5. Neither → block deployment with full actionable report

Usage:
  python3 tools/ssm_preflight.py \
    --config  cicd.config.yml \
    --env     PROD \
    --prefix  production/ingestion \
    --region  eu-west-3
"""
import argparse, json, os, re, sys
from dataclasses import dataclass, field
from pathlib import Path

import boto3, yaml
from botocore.exceptions import ClientError, NoCredentialsError

# ─────────────────────────────────────────────────────────────────────────────
# Data structures
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class ParameterResult:
    placeholder: str
    ssm_path:    str
    status:      str
    source:      str
    error:       str = ""
    
@dataclass
class preflightReport:
    environment: str
    ssm_prefix:  str
    region:      str
    results: list[ParameterResult] = field(default_factory=list)
    
    @property
    def existing(self) -> list[ParameterResult]:
        return [r for r in self.results if r.status == "exists"]

    @property
    def created(self) -> list[ParameterResult]:
        return [r for r in self.results if r.status == "created"]
    
    @property
    def missing(self) -> list[ParameterResult]:
        return [r for r in self.results if r.status == "missing"]
    
    @property
    def success(self) -> bool:
        return len(self.missing) == 0

# ─────────────────────────────────────────────────────────────────────────────
# GitHub Secrets loader
# ─────────────────────────────────────────────────────────────────────────────

def load_github_secrets() -> dict[str, str]:
    """
    Load all secrets passed by the file ci.yml via toJson(secrets).
    SECRETS_JSON is set in the env: block of _ssm_preflight.yml
    
    Returns a dict of {SECRET_NAME: value} - empty strings filtered out since Github Actions
    sets unset secrets to empty string
    """
    raw = os.environ.get("SECRETS_JSON", "{}")
    
    try:
        secrets = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"::error::SECRETS_JSON is not valid JSON: {e}")
        sys.exit(1)
    
    return {k: v for k,v in secrets.items() if v in v.strip()}

# ─────────────────────────────────────────────────────────────────────────────
# SSM Preflight
# ─────────────────────────────────────────────────────────────────────────────

class SSMPreflight:
    RUNTIMES_VARS = {"MODULE", "DEPLOYMENT_DATE"}
    
    def __init__(self, 
                 env:            str,
                 ssm_prefix:     str,
                 region:         str,
                 secrets_map:    dict[str, str],
                 github_secrets: dict[str, str], 
                 template_path:  Path | None = None,
                 ):
        self.env            = env
        self.ssm_prefix     = ssm_prefix.strip("/")
        self.region         = region
        self.secrets_map    = secrets_map
        self.github_secrets = github_secrets
        self.template_path  = template_path
        self._ssm           = boto3.client("ssm", region_name=region)
        
    def _build_ssm_path(self, placeholder: str) -> str:
        """
        Build full SSM path from placeholder name
        Example:   
            placeholder: SERVER_DB_HOST
            secrets_map: SERVER_DB_HOST -> db/host
            ssm_prefix: production/ingestion
            result: /production/ingestion/db/host
        """
        relative = self.secrets_map[placeholder]
        return f"/{self.ssm_prefix}/{relative}"
    
    def __ssm_exists(self, ssm_path: str) -> bool:
        """
        Checks if SSM parameter exists and has a non-empty value.
        Returns false if not found - raises an unexpected AWS errors
        """
        try:
            resp = self._ssm.get_parameter(Name=ssm_path, WithDecryption=False)
            return bool(resp["Parameter"]["Value"].strip())
        except self._ssm.exceptions.ParameterNotFound:
            return False
        except ClientError as e:
            raise RuntimeError(
                f"Unexpected AWS error checking '{ssm_path}': {e}"
            ) from e
            
    def _create_ssm(
        self,
        ssm_path: str,
        value: str,
        placeholder: str,
    ) -> None:
        """
        Creates a new SecureString parameter in SSM
        Overwrite=False - never silently overwrites existing values
        """
        self._ssm.put_parameter(
            Name=ssm_path, Value=value, Type="SecureString", 
            Description= f"Auto-provisioned by ssm_preflight.py \n - {self.env} \n - {placeholder}", 
            Overwrite=False
        )
    
    # -- Template cross-check 
    def _extract_placeholders(self) -> set[str]:
        """
        Reads config.template.json and extracts all {{ PLACEHOLDER }} names.
        Returns empty set if no template path provided or file not found.
        """
        if not self.template_path or not self.template_path.exists():
            return set()
        content = self.template_path.read_text(encoding="utf-8")
        return set(re.findall(r'\{\{\s*(\w+)\s*}\}', content))
    
    def _validate_template_coverage(self) -> list[str]:
        """
        Every {{ PLACEHOLDER }} in config.template.json must be declared in cicd.config.yml
        secrets_map (except runtime vars).
        
        Returns list of error message - empty lost means all covered
        """
        errors = []
        placeholders = self._extract_placeholders() - self.RUNTIMES_VARS
        
        for placeholder in sorted(placeholders):
            if placeholder not in self.secrets_map:
                errors.append(
                    f"  ❌ {{{{ {placeholder} }}}} found in "
                    f"{self.template_path.name} "
                    f"      → Add to cicd.config.yml:\n"
                    f"          {placeholders}: \"your/ssm/relative/path\""
                    )
        return errors
    
    # -- AWS credentials check 
    def _check_aws_credentials(self) -> None:
        """
        Validate AWS credentials before doing anything else.
        Exists immediately if credentials are missing or invalid 
        """
        try: 
            sts = boto3.client("sts", region_name=self.region)
            identity = sts.get_caller_identity()
            print(f"    [OK] AWS credentials valid")
            print(f"        Account : {identity['Account']}")
            print(f"        ARN     : {identity['Arn']}")
        except NoCredentialsError:
            print("  ❌ No AWS credentials found.")
            print(
                "       set AWS_ACCESS_KEY_ID and "
                "AWS_SECRET_ACCESS_KEY as Github Secrets"
            )
            sys.exit(1)
        except ClientError as e:
            print(f"  ❌ AWS credentials invalid: {e}")
            sys.exit(1)
        
    # -- Single parameter processing
    def _process(self, placeholder: str) -> ParameterResult:
        """
        Processes a single placeholder through the full resolution flow:
            1. SSM exists and non-empty -> exists 
            2. Not in SSM + Github Secret available -> create in SSM
            3. Neither -> missing (blocks deployment)
        """
        ssm_path = self._build_ssm_path(placeholder=placeholder)
        
        # Step 1 - already in SSM
        try: 
            if self.__ssm_exists(ssm_path):
                return ParameterResult(
                    placeholder=placeholder,
                    ssm_path=ssm_path,
                    status="exists",
                    source="ssm"
                )
        except Exception as e:
            return ParameterResult(
                placeholder=placeholder,
                ssm_path=ssm_path,
                status="missing",
                source="none",
                error=str(e)
            )
            
        # Step 2 - try Github Secret 
        github_value = self.github_secrets.get(placeholder, "").strip()
        if github_value:
            try:
                self._create_ssm(ssm_path=ssm_path, value=github_value, placeholder=placeholder)
                return ParameterResult(
                    placeholder=placeholder,
                    ssm_path=ssm_path,
                    status="created",
                    source="github_secret"
                )
            except ClientError as e:
                return ParameterResult(
                    placeholder=placeholder,
                    ssm_path=ssm_path,
                    status="missing",
                    source="none",
                    error=f"SSM creation failed: {e}"
                )
                
        # Step 3 - nowhere to be found 
        return ParameterResult(
            placeholder=placeholder,
            ssm_path=ssm_path,
            status="missing",
            source="none",
            error=(
                f"Not found in SSM and Github Secret "
                f"'{placeholder}' is not set or was not passed "
                f"in ci.tml secrets: block."
            )
        )
        
    # -- Main run 
    def run(self) -> preflightReport:
        """
        Runs the full preflight sequence
        Exits with code 1 if any parameter cannot be resolved
        """
        report = preflightReport(
            environment=self.env,
            ssm_prefix=self.ssm_prefix,
            region=self.region
        )
        
        print(f"\n{'=' * 60}")
        print(f"    SSM PREFLIGHT")
        print(f"    Environment : {self.env}")
        print(f"    SSM prefix  : /{self.ssm_prefix}/")
        print(f"    Region      : {self.region}")
        print(f"    Parameters  : {len(self.secrets_map)}")
        print(f"\n{'-' * 60}")
        
        # -- 1. Validate AWS credentials
        print(f"--- Checking AWS credentials ---")
        self._check_aws_credentials()
        print()
        
        # -- 2. Cross-check template vs secrets_map
        if self.template_path:
            print(
                "--- Cross-checking config.template.json "
                "vs secrets_map ---"
            )
            errors = self._validate_template_coverage()
            if errors:
                print(
                    f"\n🚨 Template coverage FAILED — "
                    f"{len(errors)} placeholder(s) not in secrets_map:\n"
                )
                for e in errors:
                    print(e)
                print(
                    "\nFix cicd.config.yml secrets_map "
                    "then re-run the pipeline.\n"
                )
                sys.exit(1)
            
            placeholders = self._extract_placeholders() - self.RUNTIMES_VARS
            print(
                f"  [OK] All {len(placeholders)} template"
                f"placeholder(s) covered by secrets_map\n"
            )
        
        # -- 3. Process each parameter in secrets_map
        print(
            f"--- Checking {len(self.secrets_map)}"
            f"SSM parameter(s) ---"
        )
        for placeholder in self.secrets_map:
            result = self._process(placeholder)
            report.results.append(result)
            
            if result.status == "exists":
                print(
                    f"  [OK]    {placeholder} \n"
                    f"          ← {result.ssm_path}"
                )
            elif result.status == "created":
                print(
                    f"  [CREATED] {placeholder}\n"
                    f"            → {result.ssm_path} "
                    f"(auto-provisionned from Github Secret)"
                )
            else:
                print(
                    f"  [MISSING] {placeholder}\n"
                    f"            → {result.ssm_path}\n"
                    f"            ⚠  {result.error}"
                )
    
        # -- 4. Final report
        print(f"\n{'='*60}")
        print(f"  SSM PREFLIGHT REPORT")
        print(f"{'='*60}")
        print(f"  ✅ Already in SSM : {len(report.existing)}")
        print(f"  🆕 Created in SSM : {len(report.created)}")
        print(f"  ❌ Missing        : {len(report.missing)}")
        print(f"{'='*60}\n")

        if report.missing:
            print("🚨 DEPLOYMENT BLOCKED — Fix the following:\n")
            for r in report.missing:
                print(f"  ❌ {r.placeholder}")
                print(f"     SSM path : {r.ssm_path}")
                print(f"     Error    : {r.error}")
                print(f"     Fix A    : Set GitHub Secret '{r.placeholder}'")
                print(f"                and add it to ci.yml secrets: block")
                print(f"     Fix B    : Provision manually:")
                print(
                    f"                aws ssm put-parameter"
                    f" --name '{r.ssm_path}'"
                    f" --value 'YOUR_VALUE'"
                    f" --type SecureString"
                    f" --region {self.region}\n"
                )
            sys.exit(1)

        print(
            "✅ All SSM parameters validated — "
            "deployment can proceed.\n"
        )
        return report

# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "SSM preflight - validate and auto-provision "
            "SSM parameter before deployment"
        )
    )
    parser.add_argument(
        "--config",
        default="cicd.config.yml",
        help="Path to cicd.config.yml (default: cicd.config.yml)"
    )
    parser.add_argument(
        "--env",
        required=True,
        help="Deployment environment (INT / UAT / production)"
    )
    parser.add_argument(
        "--prefix",
        required=True,
        help="SSM prefix without leading slash (e.g, production/ingestion)"
    )
    parser.add_argument(
        "--region",
        default="eu-west-3",
        help="AWS region (default: eu-west-3)"
    )
    args = parser.parse_args()
    
    # -- Load cicd.config.yml 
    config_path = Path(args.config)
    if not config_path.exists():
        print(f"❌ Config file not found: '{config_path}'")
        sys.exit(1)
    
    cicd = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    
    secrets_map = cicd.get("secrets_map", {})
    if not secrets_map:
        print(
            "❌ 'secrets_map' is empty in cicd.config.yml\n"
            "   Add a secrets_map section declaring your placeholders."
        )
        sys.exit(1)
    
    # -- Resolve template_path
    tmpl        = cicd.get("config_template", {})
    tmpl_path   = tmpl.get("path") if isinstance(tmpl, dict) else None
    template_path = Path(tmpl_path) if tmpl_path else None
    
    # ── Load GitHub Secrets from SECRETS_JSON env var
    # Set in _ssm_preflight.yml via: SECRETS_JSON: ${{ toJson(secrets) }}
    # Contains all secrets passed by ci.yml in its secrets: block
    github_secrets = load_github_secrets()
    
    print(
        f"  Loaded {len(github_secrets)} Github Secret(s)"
        f"from SECRETS_JSON"
    )
    
    # -- Run preflight 
    SSMPreflight(
        env=args.env,
        ssm_prefix=args.prefix,
        region=args.region,
        secrets_map=secrets_map,
        github_secrets=github_secrets,
        template_path=template_path,
    ).run()

if __name__ == "__main__":
    main()