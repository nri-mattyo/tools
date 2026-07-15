#!/usr/bin/env bash
# 

if [[ ! -f ecr-respositories${AWS_PROFILE:+-${AWS_PROFILE}}.jsonl ]]; then
    ./list-ecr-repositories.sh > ecr-respositories${AWS_PROFILE:+-${AWS_PROFILE}}.jsonl
fi
if [[ ! -f ecr-images${AWS_PROFILE:+-${AWS_PROFILE}}.jsonl ]]; then
    ./describe-ecr-images.sh > ecr-images${AWS_PROFILE:+-${AWS_PROFILE}}.jsonl
fi
if [[ ! -f ecr-lifecycle-policies${AWS_PROFILE:+-${AWS_PROFILE}}.jsonl ]]; then
    ./get-ecr-lifecycle-policies.sh > ecr-lifecycle-policies${AWS_PROFILE:+-${AWS_PROFILE}}.jsonl
fi

cat ecr-images${AWS_PROFILE:+-${AWS_PROFILE}}.jsonl \
| jq -nrc 'reduce inputs as $x ({}; .[$x.repositoryName//"none"] |= (
    .//{} | 
        .count += 1 | 
        .size += $x.imageSizeInBytes | 
        .gbs += ($x.imageSizeInBytes/1024/1024/1024) |
        .min_pushed |= (if (.//"zzz") > $x.imagePushedAt then $x.imagePushedAt else . end) |
        .min_pulled |= (if (.//"zzz") > $x.lastRecordedPullTime then $x.lastRecordedPullTime else . end)
    )
)' | jq -r . \
> ecr-images-summary${AWS_PROFILE:+-${AWS_PROFILE}}.json
