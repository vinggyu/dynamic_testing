package main

import (
	"bufio"
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"strings"
	"time"

	"github.com/google/uuid"
	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

const namespace = "default"

func main() {
	config, err := rest.InClusterConfig()
	if err != nil {
		log.Fatalf("Failed to get kubeconfig: %v", err)
	}
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		log.Fatalf("Failed to create clientset: %v", err)
	}

	listener, err := net.Listen("tcp", ":4321")
	if err != nil {
		log.Fatalf("Failed to listen on port 4321: %v", err)
	}
	defer listener.Close()

	log.Println("Pod Spawner listening on port 4321")

	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("Failed to accept connection: %v", err)
			continue
		}
		go handleConnection(conn, clientset)
	}
}

func handleConnection(userConn net.Conn, clientset *kubernetes.Clientset) {
	defer userConn.Close()
	log.Printf("Accepted connection from %s", userConn.RemoteAddr())

	_ = userConn.SetReadDeadline(time.Now().Add(2 * time.Second))
	line, _ := bufio.NewReader(userConn).ReadString('\n')
	line = strings.TrimSpace(line)

	// 기대 포맷: "wake <test-image> <tar-name>"
	fields := strings.Fields(line)

	testImg := ""
	inTar := "" // /in/<tar-name> 으로 주입할 값

	if len(fields) >= 2 {
		testImg = fields[1]
	}
	if len(fields) >= 3 {
		inTar = "/in/" + fields[2]
	}

	log.Printf("Trigger=%q, TEST_IMG=%q, IN_TAR=%q", line, testImg, inTar)

	podName := "ota-agent-pod-" + uuid.New().String()[:8]
	pod, err := createDynamicPod(clientset, podName, testImg, inTar)
	if err != nil {
		log.Printf("Failed to create pod: %v", err)
		return
	}

	podIP, err := waitForPodIP(clientset, podName)
	if err != nil {
		log.Printf("Pod %s did not become ready: %v", pod.Name, err)
		return
	}

	log.Printf("Pod %s is running with IP %s", podName, podIP)

	if err := waitForPodCompletionAndCleanup(clientset, podName); err != nil {
		log.Printf("Error while waiting for pod %s completion: %v", podName, err)
	} else {
		log.Printf("Pod %s completed and was cleaned up.", podName)
	}
}

func createDynamicPod(clientset *kubernetes.Clientset, name string, testImg string, inTar string) (*v1.Pod, error) {
	challengeImage := os.Getenv("CHALLENGE_IMAGE")
	if challengeImage == "" {
		challengeImage = "localhost/ota-agent:latest"
		log.Printf("WARNING: CHALLENGE_IMAGE is empty. Using default image: %s", challengeImage)
	}

	// hostPath는 절대경로여야 합니다.
	hostPathDir := os.Getenv("AGENT_IO_DIR")
	if hostPathDir == "" {
		hostPathDir = "/home/kuse/zta_ota/dynamic_testing/agent-io" // 환경에 맞게 바꾸세요.
		log.Printf("WARNING: AGENT_IO_DIR is empty. Using default hostPath: %s", hostPathDir)
	}

	log.Printf("Creating dynamic pod: %s with image: %s", name, challengeImage)

	privileged := true
	runAsUser := int64(0)
	runAsGroup := int64(0)
	fsGroup := int64(0)
	hostPathType := v1.HostPathDirectoryOrCreate

	envs := []v1.EnvVar{}
	if testImg != "" {
		envs = append(envs, v1.EnvVar{Name: "TEST_IMG", Value: testImg})
	}
	if inTar != "" {
		envs = append(envs, v1.EnvVar{Name: "IN_TAR", Value: inTar})
	}

	pod := &v1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: namespace,
			Labels: map[string]string{
				"app": "ota-agent-dynamic-spawn",
			},
		},
		Spec: v1.PodSpec{
			SecurityContext: &v1.PodSecurityContext{
				RunAsUser:  &runAsUser,
				RunAsGroup: &runAsGroup,
				FSGroup:    &fsGroup,
			},
			Containers: []v1.Container{
				{
					Name:            "ota-agent",
					Image:           challengeImage,
					ImagePullPolicy: v1.PullNever,
					Env:             envs,
					SecurityContext: &v1.SecurityContext{
						Privileged:               &privileged,
						AllowPrivilegeEscalation: func(b bool) *bool { return &b }(true),
					},
					VolumeMounts: []v1.VolumeMount{
						{Name: "ota-io", MountPath: "/in"},
						{Name: "ota-io", MountPath: "/out"},
					},
				},
			},
			Volumes: []v1.Volume{
				{
					Name: "ota-io",
					VolumeSource: v1.VolumeSource{
						HostPath: &v1.HostPathVolumeSource{
							Path: hostPathDir,
							Type: &hostPathType,
						},
					},
				},
			},
		},
	}

	return clientset.CoreV1().Pods(namespace).Create(context.TODO(), pod, metav1.CreateOptions{})
}

func waitForPodIP(clientset *kubernetes.Clientset, name string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Minute)
	defer cancel()

	for {
		select {
		case <-ctx.Done():
			return "", fmt.Errorf("timeout waiting for pod %s to be ready", name)
		default:
			pod, err := clientset.CoreV1().Pods(namespace).Get(ctx, name, metav1.GetOptions{})
			if err != nil {
				return "", err
			}
			if pod.Status.Phase == v1.PodRunning && pod.Status.PodIP != "" {
				return pod.Status.PodIP, nil
			}
			time.Sleep(2 * time.Second)
		}
	}
}

func waitForPodCompletionAndCleanup(clientset *kubernetes.Clientset, name string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	for {
		select {
		case <-ctx.Done():
			return fmt.Errorf("timeout waiting for pod %s to complete", name)
		default:
			pod, err := clientset.CoreV1().Pods(namespace).Get(ctx, name, metav1.GetOptions{})
			if err != nil {
				return err
			}

			switch pod.Status.Phase {
			case v1.PodSucceeded, v1.PodFailed:
				log.Printf("Pod %s finished with phase %s. Deleting...", name, pod.Status.Phase)
				deletePolicy := metav1.DeletePropagationForeground
				return clientset.CoreV1().Pods(namespace).Delete(
					context.TODO(),
					name,
					metav1.DeleteOptions{PropagationPolicy: &deletePolicy},
				)
			}
			time.Sleep(2 * time.Second)
		}
	}
}
