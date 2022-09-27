
function grid2price_256(grid) {
	const X = [
		1048576 - 1048576,
		1051419 - 1048576,
		1054270 - 1048576,
		1057128 - 1048576,
		1059994 - 1048576,
		1062868 - 1048576,
		1065750 - 1048576,
		1068639 - 1048576,
		1071537 - 1048576,
		1074442 - 1048576,
		1077355 - 1048576,
		1080276 - 1048576,
		1083205 - 1048576,
		1086142 - 1048576,
		1089087 - 1048576,
		1092040 - 1048576]

	const Y = [
		65536 - 65536,
		68438 - 65536,
		71468 - 65536,
		74632 - 65536,
		77936 - 65536,
		81386 - 65536,
		84990 - 65536,
		88752 - 65536,
		92682 - 65536,
		96785 - 65536,
		101070 - 65536,
		105545 - 65536,
		110218 - 65536,
		115098 - 65536,
		120194 - 65536,
		125515 - 65536]
	const head = Math.floor(grid / 256)
	const tail = grid % 256
	const x = X[tail % 16]
	const y = Y[Math.floor(tail / 16)]
	// eslint-disable-next-line
	const beforeShift = ((1 << 20) + x) * ((1 << 16) + y)
	// eslint-disable-next-line
	return beforeShift * Math.pow(2, head)
}


function grid2price_64(grid) {
	const X = [
		524288 - 524288,
		529997 - 524288,
		535768 - 524288,
		541603 - 524288,
		547500 - 524288,
		553462 - 524288,
		559489 - 524288,
		565581 - 524288]

	const Y = [
		65536 - 65536,
		71468 - 65536,
		77936 - 65536,
		84990 - 65536,
		92682 - 65536,
		101070 - 65536,
		110218 - 65536,
		120194 - 65536]
	const head = Math.floor(grid / 64)
	const tail = grid % 64
	const x = X[tail % 8]
	const y = Y[Math.floor(tail / 8)]
	// eslint-disable-next-line
	const beforeShift = ((1 << 19) + x) * ((1 << 16) + y)
	// eslint-disable-next-line
	return beforeShift * Math.pow(2, (1 + head))
}


function grid2price_16(grid) {
	const X = [
		65536 - 65536, // extractNthU16(Y, 0)==Math.pow(2,16)*(Math.pow(alpha, 0) -1)
		68438 - 65536, // extractNthU16(Y, 1)==Math.pow(2,16)*(Math.pow(alpha, 1) -1)
		71468 - 65536, // extractNthU16(Y, 2)==Math.pow(2,16)*(Math.pow(alpha, 2) -1)
		74632 - 65536, // extractNthU16(Y, 3)==Math.pow(2,16)*(Math.pow(alpha, 3) -1)
		77936 - 65536, // extractNthU16(Y, 4)==Math.pow(2,16)*(Math.pow(alpha, 4) -1)
		81386 - 65536, // extractNthU16(Y, 5)==Math.pow(2,16)*(Math.pow(alpha, 5) -1)
		84990 - 65536, // extractNthU16(Y, 6)==Math.pow(2,16)*(Math.pow(alpha, 6) -1)
		88752 - 65536, // extractNthU16(Y, 7)==Math.pow(2,16)*(Math.pow(alpha, 7) -1)
		92682 - 65536, // extractNthU16(Y, 8)==Math.pow(2,16)*(Math.pow(alpha, 8) -1)
		96785 - 65536, // extractNthU16(Y, 9)==Math.pow(2,16)*(Math.pow(alpha, 9) -1)
		101070 - 65536, // extractNthU16(Y,10)==Math.pow(2,16)*(Math.pow(alpha,10) -1)
		105545 - 65536, // extractNthU16(Y,11)==Math.pow(2,16)*(Math.pow(alpha,11) -1)
		110218 - 65536, // extractNthU16(Y,12)==Math.pow(2,16)*(Math.pow(alpha,12) -1)
		115098 - 65536, // extractNthU16(Y,13)==Math.pow(2,16)*(Math.pow(alpha,13) -1)
		120194 - 65536, // extractNthU16(Y,14)==Math.pow(2,16)*(Math.pow(alpha,14) -1)
		125515 - 65536 // extractNthU16(Y,15)==Math.pow(2,16)*(Math.pow(alpha,15) -1)
	]
	const head = Math.floor(grid / 16)
	const tail = grid % 16
	const x = X[tail]
	// eslint-disable-next-line
	const beforeShift = (1 << 16) + x
	// eslint-disable-next-line
	return beforeShift * Math.pow(2, (20 + head))
}

function price2grid_256(price) {
	// eslint-disable-next-line
	let a, b, c;
	for (a = 0; a < 64; a++) {
		if (grid2price_256(a * 256) > price) {
			break;
		}
	}
	a--;
	for (b = 0; b < 16; b++) {
		if (grid2price_256(a * 256 + b * 16) > price) {
			break;
		}
	}
	b--;
	for (c = 0; c < 16; c++) {
		if (grid2price_256(a * 256 + b * 16 + c) > price) {
			break;
		}
	}
	c--;
	return a * 256 + b * 16 + c
}

function price2grid_64(price) {
	// eslint-disable-next-line
	let a, b, c;
	for (a = 0; a < 64; a++) {
		if (grid2price_64(a * 64) > price) {
			break;
		}
	}
	a--;
	for (b = 0; b < 8; b++) {
		if (grid2price_64(a * 64 + b * 8) > price) {
			break;
		}
	}
	b--;
	for (c = 0; c < 8; c++) {
		if (grid2price_64(a * 64 + b * 8 + c) > price) {
			break;
		}
	}
	c--;
	return a * 64 + b * 8 + c
}

function price2grid_16(price) {
	// eslint-disable-next-line
	let a;
	let b;
	for (a = 0; a < 64; a++) {
		if (grid2price_16(a * 16) > price) {
			break;
		}
	}
	a--;
	for (b = 0; b < 16; b++) {
		if (grid2price_16(a * 16 + b) > price) {
			break;
		}
	}
	b--;
	return a * 16 + b;
}

function getResult(gridexType) {
	let price2grid
	let grid2price
	switch (gridexType) {
		case 16:
			price2grid = price2grid_16
			grid2price = grid2price_16
			break;
		case 64:
			price2grid = price2grid_64
			grid2price = grid2price_64
			break;
		case 256:
			price2grid = price2grid_256
			grid2price = grid2price_256
			break;
	}
	return {
		price2grid,
		grid2price
	}
}
module.exports.getResult = getResult;


// function test_1a() {
// 	let last = grid2price_256(0)
// 	for (let i = 1; i < 25600; i++) {
// 		let curr = grid2price_256(i)
// 		let r = curr / last
// 		if (r < 1.0027 || r > 1.00272) {
// 			console.log("Error:", i, curr, curr / last)
// 		}
// 		last = curr
// 	}
// }

// function test_1b() {
// 	for (let i = 1; i < 5220; i++) {
// 		let curr = grid2price_256(i)
// 		let j = price2grid_256(curr)
// 		let k = price2grid_256(curr * 1.001)
// 		if (i != j || i != k) {
// 			console.log("Error:", i, j, k, curr)
// 		}
// 	}
// }

// function test_2a() {
// 	let last = grid2price_64(0)
// 	for (let i = 1; i < 6400; i++) {
// 		let curr = grid2price_64(i)
// 		let r = curr / last
// 		if (r < 1.01086 || r > 1.0109) {
// 			console.log("Error:", i, curr, curr / last)
// 		}
// 		last = curr
// 	}
// }

// function test_2b() {
// 	for (let i = 1; i < 3100; i++) {
// 		let curr = grid2price_64(i)
// 		let j = price2grid_64(curr)
// 		let k = price2grid_64(curr * 1.005)
// 		if (i != j || i != k) {
// 			console.log("Error:", i, j, k, curr)
// 		}
// 	}
// }

// test_1a()
// test_1b()
// test_2a()
// test_2b()
