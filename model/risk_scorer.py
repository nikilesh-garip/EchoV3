import time

# Centralized Risk Engine Configuration
RISK_CONFIG = {
    "weights": {
        "primary_confidence": 0.35,
        "verification_confidence": 0.35,
        "media_playback_active": -0.25,      # Reduces risk to account for movie false positives
        "sudden_motion_detected": 0.15,     # Sudden motion suggests real panic/escape attempts
        "repeated_impulse_count": 0.10,     # Multi-event sequences indicate active danger zones
    },
    "thresholds": {
        "NORMAL": 30,
        "SUSPICIOUS": 60,
        "POSSIBLE_DANGER": 80,
        "HIGH_RISK": 100
    },
    # Max repeated impulses to cap the score boost
    "max_repeated_impulses": 3,
    # Lookback window for counting repeated events in seconds
    "temporal_lookback_seconds": 10.0,
    # List of classes considered hazardous (non-normal)
    "hazard_classes": [
        "gunshot", "explosion", "scream", "glass_breaking", "fire_alarm", "siren", "shouting"
    ]
}

MAX_TRACKED_CONTEXTS = 2000


class RiskScorer:
    def __init__(self, config=RISK_CONFIG):
        self.config = config
        # Keep temporal context per monitoring session/device. A process-global list
        # would let one user's sounds raise another user's risk score.
        self.event_history = {}

    def add_event(self, class_name, context_id="default"):
        """
        Maintains a rolling temporal history window of detected sounds.
        We prune any events older than our lookback configuration.
        """
        now = time.time()
        if context_id not in self.event_history and len(self.event_history) >= MAX_TRACKED_CONTEXTS:
            # context_id is an unauthenticated, client-supplied user_id, so
            # this dict is reachable by anyone -- bound it the same way
            # geocode.py's reverse-geocode cache is bounded (FIFO eviction)
            # rather than growing one entry per distinct id forever.
            self.event_history.pop(next(iter(self.event_history)), None)
        history = self.event_history.setdefault(context_id, [])
        history.append({"timestamp": now, "class": class_name})
        self.prune_history(now, context_id)

    def prune_history(self, current_time, context_id="default"):
        """
        Removes events that occurred outside the temporal lookback window.
        Reasoning: Older sounds lose relevance for context risk. Drops the
        dict key entirely once its history is empty, instead of leaving a
        `[]` behind forever -- a context that had exactly one hazard event
        and nothing since must not keep a permanent entry.
        """
        cutoff = current_time - self.config["temporal_lookback_seconds"]
        history = self.event_history.get(context_id)
        if history is None:
            return
        pruned = [e for e in history if e["timestamp"] >= cutoff]
        if pruned:
            self.event_history[context_id] = pruned
        else:
            self.event_history.pop(context_id, None)
        
    def get_repeated_impulse_count(self, context_id="default"):
        """
        Calculates the number of hazardous sounds that occurred in the recent lookback window.
        Reasoning: A sequence of sounds (e.g. Gunshot -> Scream -> Shouting) is a strong
        indicator of real emergency environments.
        """
        # Exclude the very latest event to only count "repeats" or "context" events
        history = self.event_history.get(context_id, [])
        if len(history) <= 1:
            return 0
            
        hazards = [
            e for e in history[:-1]
            if e["class"] in self.config["hazard_classes"]
        ]
        return min(len(hazards), self.config["max_repeated_impulses"])

    def calculate_risk(self, primary_conf, verification_conf, media_playback, sudden_motion, current_class, context_id="default"):
        """
        Calculates the final 0-100 risk score and maps it to a risk level.
        
        Docstrings explaining decisions:
        - primary_confidence: Initial CRNN confidence is our baseline signal.
        - verification_confidence: Long window inference confirms acoustic signature consistency.
        - media_playback_active: Reduces risk because the audio might be coming from a movie/game.
        - sudden_motion_detected: Boosts risk because user movement/run is highly correlated with danger.
        - repeated_impulse_count: Accumulating threats in the rolling history boosts risk.
        """
        weights = self.config["weights"]
        
        # The weights are percentage points, not proportions to be re-normalized.
        # For example, a 90% pass-one confidence contributes 31.5 points.
        score_sum = 100.0 * (
            weights["primary_confidence"] * primary_conf
            + weights["verification_confidence"] * verification_conf
        )
        
        # External device contexts
        if sudden_motion:
            score_sum += 100.0 * weights["sudden_motion_detected"]
            
        # Prune stale history for this context BEFORE reading it, even when
        # the current call isn't itself a hazard (a "normal" read, or an
        # unverified detection -- main.py passes current_class="normal" for
        # those). Without this, add_event()/prune_history() only ever ran
        # together on a fresh hazard, so a context that saw a hazard
        # sequence once could keep contributing a phantom repeated-impulse
        # boost to every later, unrelated score for that same user_id no
        # matter how much later -- reproduced: a NORMAL-scoring read next to
        # 1-hour-stale hazard history came back SUSPICIOUS instead. See
        # docs/DECISIONS_LOG.md #11.
        self.prune_history(time.time(), context_id)

        # Temporal risk from history
        if current_class in self.config["hazard_classes"]:
            self.add_event(current_class, context_id)

        # Get count of previous hazardous events in lookback window
        repeats = self.get_repeated_impulse_count(context_id)
        score_sum += 100.0 * weights["repeated_impulse_count"] * repeats
        
        # Apply media playback discount if active
        if media_playback:
            score_sum += 100.0 * weights["media_playback_active"]
            
        # Clamp the explicitly point-based score to the published 0--100 scale.
        normalized_score = min(100.0, max(0.0, score_sum))
        
        # 3. Categorize into risk level
        risk_score = round(normalized_score)
        
        # Mapping to categorical risk levels
        thresholds = self.config["thresholds"]
        if risk_score <= thresholds["NORMAL"]:
            level = "NORMAL"
        elif risk_score <= thresholds["SUSPICIOUS"]:
            level = "SUSPICIOUS"
        elif risk_score <= thresholds["POSSIBLE_DANGER"]:
            level = "POSSIBLE_DANGER"
        else:
            level = "HIGH_RISK"
            
        return risk_score, level
