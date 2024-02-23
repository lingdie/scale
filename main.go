package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
)

var nodeName *string
var logger = ctrl.Log.WithName("migrate-pv")

func main() {
	nodeName = flag.String("nodeName", "", "node name to delete pv and pvc")

	opts := zap.Options{Development: true}
	opts.BindFlags(flag.CommandLine)

	flag.Parse()

	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))

	c, err := client.New(ctrl.GetConfigOrDie(), client.Options{})
	if err != nil {
		logger.Error(err, "failed to create client")
		return
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)

	// find all pv in nodeName
	pvList := &corev1.PersistentVolumeList{}
	if err = c.List(context.Background(), pvList, &client.ListOptions{}); err != nil {
		return
	}

	var targetPVCList []corev1.PersistentVolumeClaim
	pvcStatusMap := new(sync.Map)
	defer recordPVCStatus(pvcStatusMap)

	for _, pv := range pvList.Items {
		if checkPVInNode(&pv, nodeName) {
			targetPVC := &corev1.PersistentVolumeClaim{}
			if err = c.Get(context.Background(), client.ObjectKey{Namespace: pv.Spec.ClaimRef.Namespace, Name: pv.Spec.ClaimRef.Name}, targetPVC); err != nil {
				return
			}
			// only migrate pvc in ns- namespace and has no -backup suffix and is bound
			if strings.HasPrefix(targetPVC.Namespace, "ns-") && !strings.HasSuffix(targetPVC.Name, "-backup") && targetPVC.Status.Phase == corev1.ClaimBound {
				targetPVCList = append(targetPVCList, *targetPVC)
				pvcStatusMap.Store(targetPVC.Namespace+"/"+targetPVC.Name, "init, ready to go")
			}
		}
	}

	var backupPVCLabels = map[string]string{
		"scale.sealos.io/node": *nodeName,
	}

	for _, pvc := range targetPVCList {
		if status, _ := pvcStatusMap.Load(pvc.Namespace + "/" + pvc.Name); status != "init, ready to go" {
			continue
		}
		// create backup pvc for target pvc.
		logger.Info("created backup pvc", "pvc", pvc.Name+"-backup", "namespace", pvc.Namespace)
		if err := c.Create(context.Background(), &corev1.PersistentVolumeClaim{
			ObjectMeta: ctrl.ObjectMeta{
				Name:      pvc.Name + "-backup",
				Namespace: pvc.Namespace,
				Labels:    backupPVCLabels,
			},
			Spec: corev1.PersistentVolumeClaimSpec{
				AccessModes:      pvc.Spec.AccessModes,
				Resources:        pvc.Spec.Resources,
				StorageClassName: pvc.Spec.StorageClassName,
			},
		}); client.IgnoreAlreadyExists(err) != nil {
			pvcStatusMap.Store(pvc.Namespace+"/"+pvc.Name, "failed to create backup pvc")
			logger.Error(err, "failed to create backup pvc", "pvc", pvc.Name+"-backup", "namespace", pvc.Namespace)
			continue
		}
		pvcStatusMap.Store(pvc.Namespace+"/"+pvc.Name, "created backup pvc")
	}

	var wg sync.WaitGroup
	for _, pvc := range targetPVCList {
		// migrate data from target pvc to backup pvc.
		if status, _ := pvcStatusMap.Load(pvc.Namespace + "/" + pvc.Name); status != "created backup pvc" {
			logger.Info("status is not created backup pvc, continue", "pvc", pvc.Name, "namespace", pvc.Namespace)
			continue
		}
		wg.Add(1)
		pvc2 := pvc
		go func() {
			defer wg.Done()
			logger.Info("migrating data from target pvc to backup pvc", "pvc", pvc2.Name, "namespace", pvc2.Namespace)
			err := migrateData(ctx, pvc2)
			if err != nil {
				logger.Error(err, "failed to migrate data from target pvc to backup pvc", "pvc", pvc2.Name, "namespace", pvc2.Namespace)
				pvcStatusMap.Store(pvc2.Namespace+"/"+pvc2.Name, "failed to migrate data from target pvc to backup pvc")
			} else {
				logger.Info("migrated data from target pvc to backup pvc", "pvc", pvc2.Name, "namespace", pvc2.Namespace)
				pvcStatusMap.Store(pvc2.Namespace+"/"+pvc2.Name, "migrated data from target pvc to backup pvc")
			}
		}()
	}
	wg.Wait()

	var originalReplicasMap = make(map[string]int32)

	for _, pvc := range targetPVCList {
		if status, _ := pvcStatusMap.Load(pvc.Namespace + "/" + pvc.Name); status != "migrated data from target pvc to backup pvc" {
			continue
		}
		// scale down stateful set in pvc namespace
		logger.Info("scaling down stateful set in pvc namespace", "pvc", pvc.Name, "namespace", pvc.Namespace)
		statefulSetList := &appsv1.StatefulSetList{}
		if err = c.List(context.Background(), statefulSetList, &client.ListOptions{Namespace: pvc.Namespace}); err != nil {
			logger.Error(err, "failed to list stateful set in pvc namespace", "pvc", pvc.Name, "namespace", pvc.Namespace)
			pvcStatusMap.Store(pvc.Namespace+"/"+pvc.Name, "failed to list stateful set in pvc namespace")
		}
		failed := false
		// scale down stateful set in pvc namespace
		for _, sSet := range statefulSetList.Items {
			// do not recover replicas if it is already scaled down
			if _, ok := originalReplicasMap[sSet.Namespace+"/"+sSet.Name]; !ok {
				originalReplicasMap[sSet.Namespace+"/"+sSet.Name] = *sSet.Spec.Replicas
			}
			if err := scaleStatefulSet(c, sSet.Namespace, sSet.Name, 0); err != nil {
				logger.Error(err, "failed to scale down stateful set in pvc namespace", "statefulSet", sSet.Name, "namespace", sSet.Namespace)
				failed = true
				break
			}
		}
		if failed {
			pvcStatusMap.Store(pvc.Namespace+"/"+pvc.Name, "failed to scale down stateful set in pvc namespace")
		} else {
			pvcStatusMap.Store(pvc.Namespace+"/"+pvc.Name, "scaled down stateful set in pvc namespace")
		}
	}

	defer func() {
		// recover stateful set replicas
		for _, pvc := range targetPVCList {
			statefulSetList := &appsv1.StatefulSetList{}
			if err = c.List(context.Background(), statefulSetList, &client.ListOptions{Namespace: pvc.Namespace}); err != nil {
				logger.Error(err, "failed to list stateful set in pvc namespace")
			}
			logger.Info("scaling to original stateful set in pvc namespace", "pvc", pvc.Name, "namespace", pvc.Namespace)
			for _, sSet := range statefulSetList.Items {
				if err := scaleStatefulSet(c, sSet.Namespace, sSet.Name, originalReplicasMap[sSet.Namespace+"/"+sSet.Name]); err != nil {
					logger.Error(err, "failed to scaled to original stateful set in pvc namespace")
				}
			}
		}
	}()

	for _, pvc := range targetPVCList {
		// if status is not "migrated data from target pvc to back up pvc", continue
		if status, _ := pvcStatusMap.Load(pvc.Namespace + "/" + pvc.Name); status != "scaled down stateful set in pvc namespace" {
			continue
		}
		// delete pvc
		logger.Info("deleting original pvc", "pvc", pvc.Name, "namespace", pvc.Namespace)
		if err := c.Delete(context.Background(), &pvc); err != nil {
			logger.Error(err, "failed to delete pvc", "pvc", pvc.Name, "namespace", pvc.Namespace)
			pvcStatusMap.Store(pvc.Namespace+"/"+pvc.Name, "failed to delete pvc")
			continue
		}
		pvcStatusMap.Store(pvc.Namespace+"/"+pvc.Name, "deleted original pvc")
	}

	for _, pvc := range targetPVCList {
		if status, _ := pvcStatusMap.Load(pvc.Namespace + "/" + pvc.Name); status != "deleted original pvc" {
			continue
		}
		statefulSetList := &appsv1.StatefulSetList{}
		if err = c.List(context.Background(), statefulSetList, &client.ListOptions{Namespace: pvc.Namespace}); err != nil {
			logger.Error(err, "failed to list stateful set in pvc namespace", "pvc", pvc.Name, "namespace", pvc.Namespace)
			pvcStatusMap.Store(pvc.Namespace+"/"+pvc.Name, "failed to list stateful set in pvc namespace")
		}
		logger.Info("scaling up stateful set in pvc namespace", "pvc", pvc.Name, "namespace", pvc.Namespace)
		failed := false
		for _, sSet := range statefulSetList.Items {
			if err := scaleStatefulSet(c, sSet.Namespace, sSet.Name, 1); err != nil {
				logger.Error(err, "failed to scale up stateful set in pvc namespace", "statefulSet", sSet.Name, "namespace", sSet.Namespace)
				failed = true
				break
			}
		}
		if failed {
			pvcStatusMap.Store(pvc.Namespace+"/"+pvc.Name, "failed to scale up stateful set in pvc namespace")
		} else {
			pvcStatusMap.Store(pvc.Namespace+"/"+pvc.Name, "scaled up stateful set in pvc namespace")
		}
	}

	// wait for stateful set to be scaled up and pvc to be bound
	time.Sleep(60 * time.Second)

	// wait for recreated pvc to be bound
	for _, pvc := range targetPVCList {
		if status, _ := pvcStatusMap.Load(pvc.Namespace + "/" + pvc.Name); status != "scaled up stateful set in pvc namespace" {
			continue
		}
		// get recreated pvc
		logger.Info("waiting for recreated pvc to be bound", "pvc", pvc.Name, "namespace", pvc.Namespace)

		ipvc := &corev1.PersistentVolumeClaim{Status: corev1.PersistentVolumeClaimStatus{Phase: corev1.ClaimPending}}
		for pendingCount, errCount := 0, 0; errCount <= 10 && pendingCount <= 30; {
			if err = c.Get(context.Background(), client.ObjectKey{Namespace: pvc.Namespace, Name: pvc.Name}, ipvc); err != nil {
				errCount++
				logger.Error(err, "failed to get recreated pvc", "pvc", pvc.Name, "namespace", pvc.Namespace)
			}
			if ipvc.Status.Phase != corev1.ClaimBound {
				pendingCount++
			} else {
				break
			}
			time.Sleep(5 * time.Second)
		}
		if ipvc.Status.Phase != corev1.ClaimBound {
			logger.Error(fmt.Errorf("recreated pvc is not bound"), "failed to wait for recreated pvc to be bound", "pvc", pvc.Name, "namespace", pvc.Namespace)
			pvcStatusMap.Store(pvc.Namespace+"/"+pvc.Name, "failed to wait for recreated pvc to be bound")
		} else {
			logger.Info("recreated pvc is bound", "pvc", ipvc.Name, "namespace", ipvc.Namespace)
			pvcStatusMap.Store(pvc.Namespace+"/"+pvc.Name, "recreated pvc is bound")
		}
	}

	for _, pvc := range targetPVCList {
		// migrate data from backup pvc to recreated pvc.
		if status, _ := pvcStatusMap.Load(pvc.Namespace + "/" + pvc.Name); status != "recreated pvc is bound" {
			continue
		}
		wg.Add(1)
		pvc2 := pvc
		go func() {
			logger.Info("migrating data from backup pvc to recreated pvc", "pvc", pvc2.Name, "namespace", pvc2.Namespace)
			defer wg.Done()
			err := recoverData(ctx, pvc2)
			if err != nil {
				logger.Error(err, "failed to migrate data from backup pvc to recreated pvc", "pvc", pvc2.Name, "namespace", pvc2.Namespace)
				pvcStatusMap.Store(pvc2.Namespace+"/"+pvc2.Name, "failed to migrate data from backup pvc to recreated pvc")
			} else {
				logger.Info("migrated data from backup pvc to recreated pvc", "pvc", pvc2.Name, "namespace", pvc2.Namespace)
				pvcStatusMap.Store(pvc2.Namespace+"/"+pvc2.Name, "migrated data from backup pvc to recreated pvc")
			}
		}()
	}

	// TODO!!: delete backup pvc manually, get the backup pvc list from the labels: key: scale.sealos.io/node, value: nodeName

	//for _, pvc := range targetPVCList {
	//	// delete backup pvc
	//	logger.Info("deleted backup pvc")
	//	if err := c.Delete(context.Background(), &corev1.PersistentVolumeClaim{
	//		ObjectMeta: ctrl.ObjectMeta{
	//			Name:      pvc.Name + "-backup",
	//			Namespace: pvc.Namespace,
	//		},
	//	}); err != nil {
	//		logger.Error(err, "failed to delete backup pvc")
	//	}
	//	logger.Info("migrated pvc success", "pvc", pvc.Name, "namespace", pvc.Namespace)
	//}
	logger.Info("originalReplicasMap", "originalReplicasMap", originalReplicasMap)

	go func() {
		wg.Wait()
		cancel()
		logger.Info("all commands are done")
	}()

	select {
	case <-sigCh:
		cancel()
	case <-ctx.Done():
	}
}

func recordPVCStatus(p *sync.Map) {
	file, _ := os.Create("pvc_status.txt")
	p.Range(func(key, value interface{}) bool {
		line := fmt.Sprintf("pvc: %v, status: %v\n", key, value)
		_, err := file.WriteString(line)
		if err != nil {
			fmt.Println(err)
			return false
		}
		return true
	})
}

func migrateData(ctx context.Context, pvc corev1.PersistentVolumeClaim) error {
	cmd := exec.CommandContext(ctx, "./bin/migrate.sh", "-n", pvc.Namespace, "-i", pvc.Name, "-o", pvc.Name+"-backup")
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to migrate data from target pvc to backup pvc, %v, %s", err, output)
	}
	return nil
}

func recoverData(ctx context.Context, pvc corev1.PersistentVolumeClaim) error {
	cmd := exec.CommandContext(ctx, "./bin/migrate.sh", "-n", pvc.Namespace, "-i", pvc.Name+"-backup", "-o", pvc.Name)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to migrate data from backup pvc to recreated pvc, %v, %s", err, output)
	}
	return nil
}

// checkPVInNode check if pv is in nodeName
func checkPVInNode(pv *corev1.PersistentVolume, nodeName *string) bool {
	if pv.Spec.NodeAffinity != nil {
		if pv.Spec.NodeAffinity.Required.NodeSelectorTerms != nil {
			for _, term := range pv.Spec.NodeAffinity.Required.NodeSelectorTerms {
				for _, requirement := range term.MatchExpressions {
					if requirement.Key == "kubernetes.io/hostname" && requirement.Operator == corev1.NodeSelectorOpIn {
						for _, value := range requirement.Values {
							if value == *nodeName {
								return true
							}
						}
					}
				}
			}
		}
	}
	return false
}

func scaleStatefulSet(c client.Client, namespace string, name string, replicas int32) error {
	for i := 0; i < 3; i++ {
		statefulSet := &appsv1.StatefulSet{}
		if err := c.Get(context.Background(), client.ObjectKey{Namespace: namespace, Name: name}, statefulSet); err != nil {
			return err
		}
		*statefulSet.Spec.Replicas = replicas
		if err := c.Update(context.Background(), statefulSet); err != nil {
			time.Sleep(3 * time.Second)
			continue
		}
		return nil
	}
	return fmt.Errorf("failed to scale stateful set")
}
