package spec_test

import (
	"path/filepath"
	"runtime"

	. "github.com/genesis-community/testkit/v2/testing"
	. "github.com/onsi/ginkgo/v2"
)

var _ = BeforeSuite(func() {
	_, filename, _, _ := runtime.Caller(0)
	KitDir, _ = filepath.Abs(filepath.Join(filepath.Dir(filename), "../"))
})

var _ = Describe("Vault Kit", func() {

	Describe("small-footprint", func() {
		Test(Environment{
			Name:        "base",
			CloudConfig: "aws",
			CPI:         "aws",
		})
		Test(Environment{
			Name:        "base-all-params",
			CloudConfig: "aws",
			CPI:         "aws",
		})

		Test(Environment{
			Name:        "azure",
			CloudConfig: "azure",
			CPI:         "azure",
		})
		
		Test(Environment{
			Name:        "stackit",
			CloudConfig: "stackit",
			CPI:         "stackit",
		})
	})
})
