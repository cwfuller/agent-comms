"""The implementer classifier's POLICY: Jev's raw answers -> the ten `route` keys.

One function, used by BOTH `route.sh` (production) and `route_eval.py` (offline replay), so a
candidate policy the eval scores is the code production would run, never a re-implementation that
can drift. Production calls it with no `params`; the eval passes overrides of IMPLEMENTER_DEFAULTS.

It never names a vendor model id and never selects a reviewer.
"""

LEVELS = ("mechanical", "standard", "hard", "architectural")
EFFORTS = ("low", "medium", "high", "xhigh")
TIERS = ("fast", "balanced", "strong")
TIER_OF = {
    "mechanical": "fast",
    "standard": "balanced",
    "hard": "strong",
    "architectural": "strong",
}
RANK = {"fast": 0, "balanced": 1, "strong": 2}

# implementer-bump-v1. A different mapping must get a different policy NAME (route.sh
# POLICY_VARIANT) so recorded rows stay comparable; these knobs exist for offline replay.
IMPLEMENTER_DEFAULTS = {
    "plan_noul_min": 0.7,            # needs_plan score at or above which planning is considered
    "plan_levels": ("2", "3"),       # ...and only for hard / architectural work
    "complexity_conf_min": 0.5,      # below: no plan, and the tier is held at the middle
    "effort_conf_min": 0.6,          # below: effort falls back to medium
    "bump": True,                    # raise effort and tier one step after classification
    "downgrade_max_context": 20000,  # cache-sticky: no tier downgrade past this context size
}


class PolicyError(ValueError):
    """An answer the policy cannot use. The caller fails open with this reason."""


def _unit(value, what):
    try:
        v = float(value)
    except (TypeError, ValueError):
        raise PolicyError(f"{what} is missing or not a number")
    if v != v or v < 0.0 or v > 1.0:
        raise PolicyError(f"{what} is out of range")
    return v


def _step_up(seq, value):
    try:
        i = seq.index(value)
    except ValueError:
        return value
    return seq[min(i + 1, len(seq) - 1)]


def map_implementer(answers, *, policy_variant, backend_name, overrides=None,
                    current_tier="", context_tokens=0, params=None):
    """Raw answers -> dict of the ten keys. Raises PolicyError on an unusable answer."""
    p = dict(IMPLEMENTER_DEFAULTS)
    p.update(params or {})
    overrides = overrides or {}

    noul_ans = answers.get("needs_plan")
    score_ans = answers.get("complexity")
    choice_ans = answers.get("effort")
    if not isinstance(noul_ans, dict) or not isinstance(score_ans, dict) or not isinstance(choice_ans, dict):
        raise PolicyError("response is missing needs_plan, complexity, or effort")

    plan_p = _unit(noul_ans.get("noul"), "needs_plan.noul")
    probs = score_ans.get("probabilities")
    if not isinstance(probs, dict) or not probs:
        raise PolicyError("complexity.probabilities is missing")
    cconf = _unit(score_ans.get("confidence"), "complexity.confidence")

    best_p = -1.0
    best_level = "0"
    for idx in ("0", "1", "2", "3"):
        raw = 0 if idx not in probs else probs[idx]
        prob = _unit(raw, f"complexity.probabilities[{idx}]")
        if prob > best_p:
            best_p = prob
            best_level = idx
    complexity = LEVELS[int(best_level)]

    choice = choice_ans.get("choice")
    econf = _unit(choice_ans.get("confidence"), "effort.confidence")
    if choice not in EFFORTS:
        raise PolicyError("effort.choice is not a known effort")
    effort_p = None
    eprobs = choice_ans.get("probabilities")
    if isinstance(eprobs, dict) and choice in eprobs:
        effort_p = _unit(eprobs[choice], f"effort.probabilities[{choice}]")

    plan = "no"
    if (plan_p >= p["plan_noul_min"] and best_level in tuple(p["plan_levels"])
            and cconf >= p["complexity_conf_min"]):
        plan = "yes"

    effort = choice
    if econf < p["effort_conf_min"]:
        effort = "medium"
        effort_p = None

    # Abstract tier is composed HERE, not asked of Jev: the helper never names a vendor model id
    # (claude/codex/grok each map the band). Low confidence refuses fast (and plan); the gate name
    # records that choice, not the post-bump tier.
    tier = TIER_OF[complexity]
    gate = "classify"
    if cconf < p["complexity_conf_min"]:
        tier = "balanced"
        gate = "low-confidence-middle"

    # Prefer slightly more reasoning / a stronger model than the raw classification. Fail-open and
    # prompt overrides skip this (they never reach here). Cache-sticky still refuses a downgrade.
    if p["bump"]:
        effort = _step_up(EFFORTS, effort)
        if effort != choice:
            effort_p = None
        tier = _step_up(TIERS, tier)

    if current_tier in RANK and context_tokens > p["downgrade_max_context"] and RANK[tier] < RANK[current_tier]:
        tier = current_tier
        gate = "cache-sticky"

    if overrides:
        if "plan" in overrides:
            plan = overrides["plan"]
        if "effort" in overrides:
            effort = overrides["effort"]
            effort_p = None
        if "tier" in overrides:
            tier = overrides["tier"]
        gate = "override"

    plan_p_s = f"{plan_p:.3f}"
    effort_p_s = f"{effort_p:.3f}" if effort_p is not None else "-"
    cconf_s = f"{cconf:.3f}"
    reason = (
        f"policy={policy_variant} needs_plan={plan_p_s} complexity={complexity} "
        f"(level {best_level}, conf {cconf_s}) effort={effort} "
        f"(classified {choice}, conf {econf:.3f}) tier={tier} gate={gate}"
    )
    return {
        "plan": plan, "effort": effort, "complexity": complexity, "tier": tier, "gate": gate,
        "plan_p": plan_p_s, "effort_p": effort_p_s, "complexity_confidence": cconf_s,
        "source": backend_name, "reason": reason,
    }
