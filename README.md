本脚本用于将某节点中的pvc迁移到另一个节点中

## 使用方法
需要将目标节点打上污点，防止pvc仍调度在该节点上：
    key: scale.sealos.io/node
    value: "true"
    effect: NoSchedule

执行二进制文件：
```shell
./scale --nodeName=targetNodeName
```