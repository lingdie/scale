build:
	GOARCH=amd64 GOOS=linux go build -o bin/scale &&  scp bin/scale sealos-gzg:/root/yy/scale/

kube-test-init:
	kubectl create ns ns-aaa || true
	kubectl create ns ns-bbb || true
	kubectl create ns ns-ccc || true
	kubectl apply -f test -n ns-aaa
	kubectl apply -f test -n ns-bbb
	kubectl apply -f test -n ns-ccc
	kubectl exec -n ns-aaa hello-world-0 -- touch /data/aaa
	kubectl exec -n ns-aaa hello-world-0 -- touch /data-2/aaa
	kubectl exec -n ns-bbb hello-world-0 -- touch /data/bbb
	kubectl exec -n ns-bbb hello-world-0 -- touch /data-2/bbb
	kubectl exec -n ns-ccc hello-world-0 -- touch /data/ccc
	kubectl exec -n ns-ccc hello-world-0 -- touch /data-2/ccc


kube-test:
	kubectl exec -n ns-aaa hello-world-0 -- ls /data
	kubectl exec -n ns-aaa hello-world-0 -- ls /data-2
	kubectl exec -n ns-bbb hello-world-0 -- ls /data
	kubectl exec -n ns-bbb hello-world-0 -- ls /data-2
	kubectl exec -n ns-ccc hello-world-0 -- ls /data
	kubectl exec -n ns-ccc hello-world-0 -- ls /data-2

kube-test-clean:
	kubectl delete ns ns-aaa ns-bbb ns-ccc
