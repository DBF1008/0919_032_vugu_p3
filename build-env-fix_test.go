package vugu

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestRunBuildPassNumNoWrap verifies that after well over 256 build passes the
// pass tracker has not wrapped back to zero. With a uint8 a live component
// could be confused for a stale entry and destroyed.
func TestRunBuildPassNumNoWrap(t *testing.T) {

	assert := assert.New(t)

	be, err := NewBuildEnv()
	assert.NoError(err)

	root := &fixRoot{}

	const passes = 300
	for i := 0; i < passes; i++ {
		be.RunBuild(root)
	}

	// a uint8 would be 300 % 256 = 44 here and have wrapped through zero
	assert.Equal(uint64(passes), be.passNum)

	// the always-present child must still be the same instance and never destroyed
	st, ok := be.compStateMap[root.persistChild()]
	assert.True(ok)
	assert.Equal(uint64(passes), st.passNum)
	assert.Equal(1, root.persistChild().initCount)
	assert.Equal(0, root.persistChild().destroyCount)
}

// TestRunBuildDestroyStaleComponent confirms components dropped from the tree
// are destroyed exactly once and are not seen again.
func TestRunBuildDestroyStaleComponent(t *testing.T) {

	assert := assert.New(t)

	be, err := NewBuildEnv()
	assert.NoError(err)

	root := &fixRoot{showOptional: true, opt: &fixChild{id: "opt"}}
	be.RunBuild(root)
	opt1 := root.optionalChild()
	assert.Equal(1, opt1.initCount)
	assert.Equal(0, opt1.destroyCount)

	// remove the optional component and build twice
	root.showOptional = false
	be.RunBuild(root)
	be.RunBuild(root)

	assert.Equal(1, opt1.destroyCount)
	_, stillTracked := be.compStateMap[opt1]
	assert.False(stillTracked)

	// bring it back with a new instance: Init runs again and Destroy is not repeated
	opt2 := &fixChild{id: "re-added"}
	root.opt = opt2
	root.showOptional = true
	be.RunBuild(root)
	assert.NotEqual(opt1, opt2)
	assert.Equal(1, opt2.initCount)
	assert.Equal(1, opt1.destroyCount)
}

// TestRunBuildPanicRestoresCache verifies that when a child panics partway
// through a build the components already pulled from the cache via
// CachedComponent (but not yet committed with UseComponent) are preserved, so
// the next successful build reuses them rather than recreating them.
func TestRunBuildPanicRestoresCache(t *testing.T) {

	assert := assert.New(t)

	be, err := NewBuildEnv()
	assert.NoError(err)

	root := &fixRoot{}
	key := MakeCompKey(999, 0)

	// initialize the internal maps first
	be.RunBuild(root)

	// register a component as if generated code had used it in a prior pass
	child := &fixChild{id: "cached"}
	root.lookupKey = key
	root.useLookup = true
	be.UseComponent(key, child)
	be.RunBuild(root)
	assert.Equal(1, child.initCount)

	// this pass panics while the component is checked out of the cache
	root.panicAfterLookup = true
	func() {
		defer func() {
			assert.NotNil(recover())
		}()
		be.RunBuild(root)
	}()

	// next successful build must reuse the exact same instance
	root.panicAfterLookup = false
	be.RunBuild(root)
	assert.Equal(child, be.compUsed[key], "cached component was lost after panic and got recreated")
	assert.Equal(1, child.initCount, "cached component was reinitialized after panic")
}

// TestRunBuildWireFuncInvoked verifies SetWireFunc actually reaches every
// component built by buildOne, including the root component.
func TestRunBuildWireFuncInvoked(t *testing.T) {

	assert := assert.New(t)

	be, err := NewBuildEnv()
	assert.NoError(err)

	root := &fixRoot{showOptional: true, opt: &fixChild{id: "opt"}}
	var wired []*fixChild
	var rootWired int
	be.SetWireFunc(func(c Builder) {
		switch cc := c.(type) {
		case *fixRoot:
			rootWired++
		case *fixChild:
			wired = append(wired, cc)
		}
	})

	be.RunBuild(root)
	be.RunBuild(root)

	assert.Equal(2, rootWired, "root component was never wired")

	// both children are wired on each pass
	assert.Contains(wired, root.persistChild())
	assert.Contains(wired, root.optionalChild())
	assert.GreaterOrEqual(len(wired), 4)
}

// fixChild is a component that records its own lifecycle calls.
type fixChild struct {
	id           string
	initCount    int
	destroyCount int
}

func (c *fixChild) Init() {
	c.initCount++
}

func (c *fixChild) Destroy() {
	c.destroyCount++
}

func (c *fixChild) Build(in *BuildIn) *BuildOut {
	return &BuildOut{}
}

// fixRoot is a component tree used by the tests above.
type fixRoot struct {
	persist fixChild
	opt     *fixChild

	showOptional bool

	lookupKey        CompKey
	useLookup        bool
	panicAfterLookup bool

	lookup *fixChild
}

func (b *fixRoot) persistChild() *fixChild  { return &b.persist }
func (b *fixRoot) optionalChild() *fixChild { return b.opt }

func (b *fixRoot) Build(in *BuildIn) *BuildOut {

	out := &BuildOut{}

	out.Components = append(out.Components, &b.persist)

	if b.useLookup {
		c, _ := in.BuildEnv.CachedComponent(b.lookupKey).(*fixChild)
		if c == nil {
			c = &fixChild{id: "created"}
		}
		if b.panicAfterLookup {
			// panic after removing the component from the cache but before
			// it is committed with UseComponent
			panic("simulated build failure")
		}
		in.BuildEnv.UseComponent(b.lookupKey, c)
		b.lookup = c
		out.Components = append(out.Components, c)
	}

	if b.showOptional {
		out.Components = append(out.Components, b.opt)
	}

	return out
}
