package vugu

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestBuildEnvCachedComponent(t *testing.T) {

	assert := assert.New(t)

	be, err := NewBuildEnv()
	assert.NoError(err)
	assert.NotNil(be)

	{ // just double check sane behavior for these keys
		k1 := MakeCompKey(1, 1)
		k2 := MakeCompKey(1, 1)
		assert.Equal(k1, k2)
		k3 := MakeCompKey(1, 2)
		assert.NotEqual(k1, k3)
		k4 := MakeCompKey(1, 1)
		assert.Equal(k1, k4)
	}

	rb1 := &rootb1{}

	// first run to intialize
	res := be.RunBuild(rb1)
	assert.NotNil(res)

	c := be.CachedComponent(MakeCompKey(1, 1))
	assert.Nil(c)
	assert.Nil(be.compCache[MakeCompKey(1, 1)])

	b1 := &testb1{}
	be.UseComponent(MakeCompKey(1, 1), b1)
	assert.NotNil(be.compUsed[MakeCompKey(1, 1)])

	// run another one
	res = be.RunBuild(rb1)
	assert.NotNil(res)

	// we should see b1 in the cache
	assert.NotNil(be.compCache[MakeCompKey(1, 1)])
	assert.Equal(b1, be.compCache[MakeCompKey(1, 1)])

	// TODO: but not in the used (not used for this pass)

	// TODO: now try to use it and make sure we can only get it once

}

type rootb1 struct{}

func (b *rootb1) Build(in *BuildIn) (out *BuildOut) {
	return &BuildOut{
		Out: []*VGNode{},
	}
}

type testb1 struct{}

func (b *testb1) Build(in *BuildIn) (out *BuildOut) {
	return &BuildOut{
		Out: []*VGNode{},
	}
}

// trackedComp records its Init and Destroy lifecycle calls.
type trackedComp struct {
	initCalls    int
	destroyCalls int

	// mode "panic": Build panics
	mode string
}

func (c *trackedComp) Build(in *BuildIn) *BuildOut {
	if c.mode == "panic" {
		panic("trackedComp build panic")
	}
	return &BuildOut{}
}

func (c *trackedComp) Init() {
	c.initCalls++
}

func (c *trackedComp) Destroy() {
	c.destroyCalls++
}

// trackedRoot optionally emits a set of child components.
type trackedRoot struct {
	children []Builder
	mode     string
}

func (r *trackedRoot) Build(in *BuildIn) *BuildOut {
	if r.mode == "panic" {
		panic("trackedRoot build panic")
	}
	return &BuildOut{Components: r.children}
}

// TestBuildEnvPassNumNoWrap verifies that the pass counter cannot realistically
// wrap around: a wrapping uint8 would cause components removed on the wrap pass
// to retain a passNum equal to the new value and therefore never be destroyed
// (and would corrupt lifecycle handling of the DOM tree).
func TestBuildEnvPassNumNoWrap(t *testing.T) {

	assert := assert.New(t)

	be, err := NewBuildEnv()
	assert.NoError(err)

	root := &trackedRoot{}
	child := &trackedComp{}

	// build 260 passes (far past the uint8 wrap point of 256)
	for i := 0; i < 260; i++ {
		root.children = []Builder{child}
		assert.NotPanics(func() { be.RunBuild(root) })
	}

	// the pass counter must still hold a value past the uint8 boundary:
	// a uint8 would have wrapped to 4 here and risk matching stale entries
	assert.Equal(uint64(260), be.passNum)

	// the child must still be the same live instance, initialized only once
	assert.Equal(1, child.initCalls)
	assert.Equal(0, child.destroyCalls)

	// remove the child exactly once
	root.children = nil
	assert.NotPanics(func() { be.RunBuild(root) })
	assert.Equal(1, child.destroyCalls)

	// bringing it back reinitializes exactly once
	root.children = []Builder{child}
	assert.NotPanics(func() { be.RunBuild(root) })
	assert.Equal(2, child.initCalls)
	assert.Equal(1, child.destroyCalls)
}

// TestBuildEnvPanicPreservesUnusedCache verifies that when a child Build
// panics, cached components which were swapped into compCache but not yet
// consumed via UseComponent survive into the next pass rather than being
// dropped and recreated (which would lose their state).
func TestBuildEnvPanicPreservesUnusedCache(t *testing.T) {

	assert := assert.New(t)

	be, err := NewBuildEnv()
	assert.NoError(err)

	survivorKey := MakeCompKey(100, 1)
	panicKey := MakeCompKey(200, 1)

	survivor := &trackedComp{mode: "normal"}
	panicComp := &trackedComp{mode: "panic"}

	// seed the cache via a completed pass: after this the two components are
	// in compUsed and will be swapped into compCache for the next pass
	seedRoot := &seedConsumingRoot{
		be:          be,
		survivorKey: survivorKey,
		survivor:    survivor,
		panicKey:    panicKey,
		panicComp:   panicComp,
	}
	assert.NotPanics(func() { be.RunBuild(seedRoot) })

	// a nested build panics while survivor is still sitting untouched in
	// compCache (it has not been fetched or used in this pass yet)
	panicRoot := &panicConsumingRoot{
		panicComp: panicComp,
	}

	assert.Panics(func() { be.RunBuild(panicRoot) })

	// run a successful pass: the swap then exposes the prior compUsed as the
	// new compCache pool, and the survivor must be the same instance rather
	// than recreated (state preserved)
	assert.NotPanics(func() { be.RunBuild(&trackedRoot{}) })

	c := be.CachedComponent(survivorKey)
	assert.Equal(survivor, c)
}

// panicConsumingRoot models a build that panics via a nested child while
// unrelated entries remain untouched in the compCache pool.
type panicConsumingRoot struct {
	panicComp Builder
}

func (r *panicConsumingRoot) Build(in *BuildIn) *BuildOut {
	// recurse into the component that panics
	return &BuildOut{Components: []Builder{r.panicComp}}
}

// seedConsumingRoot registers both components as used during a successful
// pass so they become available in compCache on the following pass.
type seedConsumingRoot struct {
	be          *BuildEnv
	survivorKey CompKey
	survivor    Builder
	panicKey    CompKey
	panicComp   Builder
}

func (r *seedConsumingRoot) Build(in *BuildIn) *BuildOut {
	r.be.UseComponent(r.survivorKey, r.survivor)
	r.be.UseComponent(r.panicKey, r.panicComp)
	return &BuildOut{}
}

// plainBuilder is a component that never calls WireComponent itself.
type plainBuilder struct {
	name string
}

func (c *plainBuilder) Build(in *BuildIn) *BuildOut {
	return &BuildOut{}
}

// TestBuildEnvWireComponentDuringBuild verifies the wire function is invoked
// for components traversed by buildOne, including components that are reused
// from the cache (which generated code does not call WireComponent for).
func TestBuildEnvWireComponentDuringBuild(t *testing.T) {

	assert := assert.New(t)

	be, err := NewBuildEnv()
	assert.NoError(err)

	var wired []Builder
	be.SetWireFunc(func(b Builder) {
		wired = append(wired, b)
	})

	child := &plainBuilder{name: "child"}
	root := &trackedRoot{children: []Builder{child}}

	// first pass: both root and child must be wired
	wired = nil
	assert.NotPanics(func() { be.RunBuild(root) })
	assert.Contains(wired, root)
	assert.Contains(wired, child)

	// second pass: reused-from-cache components must still be wired
	wired = nil
	assert.NotPanics(func() { be.RunBuild(root) })
	assert.Contains(wired, root)
	assert.Contains(wired, child)
}
