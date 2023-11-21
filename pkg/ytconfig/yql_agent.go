package ytconfig

import (
	ytv1 "github.com/ytsaurus/yt-k8s-operator/api/v1"
	"github.com/ytsaurus/yt-k8s-operator/pkg/consts"
)

type ClusterMapping struct {
	Name    string `yson:"name"`
	Cluster string `yson:"cluster"`
	Default bool   `yson:"default"`
}

type GatewayConfig struct {
	MRJobBinary    string           `yson:"mr_job_bin"`
	UDFDirectory   string           `yson:"mr_job_udfs_dir"`
	ClusterMapping []ClusterMapping `yson:"cluster_mapping"`
}

type YQLAgent struct {
	GatewayConfig          GatewayConfig `yson:"gateway_config"`
	YqlPluginSharedLibrary string        `yson:"yql_plugin_shared_library"`

	// For backward compatibility.
	MRJobBinary        string            `yson:"mr_job_binary"`
	UDFDirectory       string            `yson:"udf_directory"`
	AdditionalClusters map[string]string `yson:"additional_clusters"`
	DefaultCluster     string            `yson:"default_cluster"`
}

type YQLAgentServer struct {
	CommonServer
	User     string   `yson:"user"`
	YQLAgent YQLAgent `yson:"yql_agent"`
}

func getYQLAgentLogging(spec *ytv1.YQLAgentSpec) Logging {
	return createLogging(
		&spec.InstanceSpec,
		"yql-agent",
		[]ytv1.TextLoggerSpec{defaultInfoLoggerSpec(), defaultDebugLoggerSpec(), defaultStderrLoggerSpec()})
}

func getYQLAgentServerCarcass(spec *ytv1.YQLAgentSpec) (YQLAgentServer, error) {
	var c YQLAgentServer
	c.RPCPort = consts.YQLAgentRPCPort
	c.MonitoringPort = consts.YQLAgentMonitoringPort

	c.User = "yql_agent"

	c.YQLAgent.GatewayConfig.UDFDirectory = "/usr/lib/yql"
	c.YQLAgent.GatewayConfig.MRJobBinary = "/usr/bin/mrjob"
	c.YQLAgent.YqlPluginSharedLibrary = "/usr/lib/yql/libyqlplugin.so"

	// For backward compatibility.
	c.YQLAgent.UDFDirectory = "/usr/lib/yql"
	c.YQLAgent.MRJobBinary = "/usr/bin/mrjob"

	c.Logging = getYQLAgentLogging(spec)

	return c, nil
}
