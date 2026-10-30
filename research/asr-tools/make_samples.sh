#!/bin/bash
# 英語の合成音声サンプルを作る(再現性のある入力用)。実際の会議音声ではない点に注意。
set -e
cd "$(dirname "$0")/.."
mkdir -p samples
VOICE=Samantha
if ! say -v '?' | grep -q "^$VOICE"; then VOICE=""; echo "Samantha がないため既定の声を使います"; fi
V=${VOICE:+-v $VOICE}
say $V -o samples/tts1.aiff "Thanks for joining us today. [[slnc 700]] Could you walk us through your background and what drew you to this role? [[slnc 900]] So, um, the main thing we're looking at this quarter is reducing the latency of the pipeline. [[slnc 700]] We use MCP servers to connect the model to internal tools, and we've been iterating on the evaluation harness. [[slnc 900]] Any questions before we move on to the next agenda item?"
say $V -r 210 -o samples/tts2_fast.aiff "Honestly, I think the trade-off here is between accuracy and response time, and we need to decide which one matters more for our customers, [[slnc 300]] but the timeline depends on the security review, so let's loop in the data team before we finalize the plan. [[slnc 1200]] Do you have any experience working with distributed teams across different time zones?"
# 長い無音(3秒)を挟む: 無音の長さと確定の関係を見る
say $V -o samples/tts3_longpause.aiff "Let me think about that for a moment. [[slnc 3000]] I believe the main risk is the schedule. [[slnc 3000]] We should talk to the security team."
# 無音なしで長く話し続ける: 強制的な区切りがあるかを見る
say $V -r 190 -o samples/tts4_continuous.aiff "So what we have been doing over the past few months is working closely with the platform team to redesign how the service handles incoming requests and then we moved the heavy processing into a background queue which meant that the response time for most customers dropped significantly and at the same time we had to rethink how errors are reported because previously a failure would just disappear silently and nobody would notice until a customer complained about it later in the week."
ls -la samples
