package postgres

import "testing"

func TestModelPriceMutationsAreVisible(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			accountID, model := uniqueID("price-account"), "model"
			assertPrice := func(wantInput, wantOutput int64, wantFound bool) {
				t.Helper()
				input, output, found := backend.GetModelPrice(accountID, model)
				if input != wantInput || output != wantOutput || found != wantFound {
					t.Fatalf("GetModelPrice = (%d, %d, %t), want (%d, %d, %t)", input, output, found, wantInput, wantOutput, wantFound)
				}
			}
			setPrice := func(input, output int64) {
				t.Helper()
				if err := backend.SetModelPrice(accountID, model, input, output); err != nil {
					t.Fatal(err)
				}
				assertPrice(input, output, true)
			}
			assertPrice(0, 0, false)
			setPrice(10, 20)
			setPrice(30, 40)
			if err := backend.DeleteModelPrice(accountID, model); err != nil {
				t.Fatal(err)
			}
			assertPrice(0, 0, false)
			setPrice(50, 60)
		})
	}
}
