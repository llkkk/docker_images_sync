#!/bin/bash
set -eux


# 检查参数数量是否正确
if [ "$#" -ne 3 ]; then
    echo "错误：脚本需要3个参数 images_file、docker_registry和docker_namespace"
    echo "用法: $0 <images_file> <docker_registry> <docker_namespace>"
    exit 1
fi


IMAGES_FILE=$1
TARGET_REGISTRY=$2
TARGET_NAMESPACE=$3

# 检查文件是否存在
if [ ! -f "$IMAGES_FILE" ]; then
    echo "错误：文件 $IMAGES_FILE 不存在"
    exit 1
fi

# 解析镜像名称，返回仓库名、镜像名和标签
parse_image_name() {
    local image="$1"
    local registry=""
    local repo=""
    local name=""
    local tag="latest"

    # 检查是否包含标签
    if [[ "$image" == *:* ]]; then
        tag="${image##*:}"
        image_without_tag="${image%:*}"
    else
        image_without_tag="$image"
    fi

    # 解析仓库和镜像名
    if [[ "$image_without_tag" == */* ]]; then
        # 处理包含仓库的情况
        # 查找第一个斜线的位置
        first_slash_index=$(expr index "$image_without_tag" /)
        
        # 检查是否为registry（包含.或:）
        possible_registry="${image_without_tag%%/*}"
        if [[ "$possible_registry" == *.* ]] || [[ "$possible_registry" == *:* ]]; then
            # 包含registry
            registry="$possible_registry"
            remaining="${image_without_tag#*/}"
        else
            # 不包含registry
            remaining="$image_without_tag"
        fi
        
        # 提取repo和name
        if [[ "$remaining" == */* ]]; then
            # 包含repo
            repo="${remaining%%/*}"
            name="${remaining#*/}"
        else
            # 不包含repo
            name="$remaining"
        fi
    else
        # 简单镜像名，不包含仓库
        name="$image_without_tag"
    fi

    # 构建结果
    local full_name
    if [[ -n "$repo" ]]; then
        full_name="$repo/$name"
    else
        full_name="$name"
    fi

    echo "$full_name $tag"
}

# 将包含斜杠的镜像名称转换为单级名称，用于阿里云推送
sanitize_image_name() {
    local full_name="$1"
    local sanitized_name
    
    # 将所有斜杠替换为下划线
    sanitized_name="${full_name////_}"
    
    echo "$sanitized_name"
}

failed_count=0
failed_images=""
while IFS= read -r image; do
    # 拉取镜像
    set +e
    docker pull "$image"
    pull_status=$?
    if [ $pull_status -ne 0 ]; then
        echo "Error: Failed to pull image $image, continuing..."
        failed_count=$((failed_count + 1))
        failed_images="${failed_images} ${image}"
        continue
    fi

    read -r full_name tag <<< $(parse_image_name "$image")
    # 对full_name进行处理，将斜杠替换为下划线
    sanitized_name=$(sanitize_image_name "$full_name")
    targetFullName=${TARGET_REGISTRY}/${TARGET_NAMESPACE}/${sanitized_name}

    # 如果有标签，添加到目标名称
    if [[ "$tag" != "latest" ]]; then
        targetFullName="${targetFullName}:${tag}"
    fi

    # 打阿里云的tag
    docker tag "${image}" "${targetFullName}"
    tag_status=$?

    # 推送到阿里云
    set +e
    docker push "${targetFullName}"
    push_status=$?
    if [ $push_status -ne 0 ]; then
        echo "Error: Failed to push image $targetFullName, continuing..."
        failed_count=$((failed_count + 1))
        failed_images="${failed_images} ${image}"
        continue
    fi
done < "$IMAGES_FILE"

if [ $failed_count -gt 0 ]; then
    echo "Error: Failed to sync $failed_count images: $failed_images"
    exit 1
fi
echo "Successfully synced all images."