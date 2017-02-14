/* This file is the current iteration of research being done to implement the
swept rule for Partial differential equations in one discion.  This research
is a collaborative effort between teams at MIT, Oregon State University, and
Purdue University.

Copyright (C) 2015 Kyle Niemeyer, niemeyek@oregonstate.edu AND
Daniel Magee, mageed@oregonstate.edu

This program is free software: you can redistribute it and/or modify
it under the terms of the MIT license.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

You should have received a copy of the MIT license
along with this program.  If not, see <https://opensource.org/licenses/MIT>.
*/

//COMPILE LINE!
// nvcc -o ./bin/KSOut KS1D_SweptShared.cu -gencode arch=compute_35,code=sm_35 -lm -restrict -Xcompiler -fopenmp --ptxas-options=-v

#include <cuda.h>
#include <cuda_runtime_api.h>
#include <cuda_runtime.h>
#include <device_functions.h>

#include <iostream>
#include <ostream>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <fstream>


#ifndef REAL
#define REAL        float
#define ONE         1.f
#define TWO         2.f
#define FOUR        4.f
#define SIX			6.f
#else
#define ONE         1.0
#define TWO         2.0
#define FOUR        4.0
#define SIX			6.0
#endif

using namespace std;

const REAL dx = 0.5;

struct discConstants{

	REAL dxTimes4;
	REAL dx2;
	REAL dx4;
	REAL dt;
	REAL dt_half;
	int base;
	int ht;
    int idxend;
};

__constant__ discConstants disc;

//Initial condition.
__host__
REAL initFun(REAL xnode)
{
	return TWO * cos(19.0*xnode*M_PI/128.0);
}

//Read in the data from the global right/left variables to the shared temper variable.
__device__
__forceinline__
void
readIn(REAL *temp, const REAL *rights, const REAL *lefts, int td, int gd)
{
	int leftidx = disc.ht + (((td>>2) & 1) * disc.base) + (td & 3) - (4 + ((td>>2)<<1));
	int rightidx = disc.ht + (((td>>2) & 1) * disc.base) + ((td>>2)<<1) + (td & 3);

	temp[leftidx] = rights[gd];
	temp[rightidx] = lefts[gd];
}

__device__
__forceinline__
void
writeOutRight(REAL *temp, REAL *rights, REAL *lefts, int td, int gd, int bd)
{
	int gdskew = (gd + bd) & disc.idxend;
    int leftidx = (((td>>2) & 1)  * disc.base) + ((td>>2)<<1) + (td & 3) + 2;
    int rightidx = (disc.base-6) + (((td>>2) & 1)  * disc.base) + (td & 3) - ((td>>2)<<1);
	rights[gdskew] = temp[rightidx];
	lefts[gd] = temp[leftidx];
}


__device__
__forceinline__
void
writeOutLeft(REAL *temp, REAL *rights, REAL *lefts, int td, int gd, int bd)
{
	int gdskew = (gd - bd) & disc.idxend;
    int leftidx = (((td>>2) & 1)  * disc.base) + ((td>>2)<<1) + (td & 3) + 2;
    int rightidx = (disc.base-6) + (((td>>2) & 1)  * disc.base) + (td & 3) - ((td>>2)<<1);
	rights[gd] = temp[rightidx];
	lefts[gdskew] = temp[leftidx];
}

#ifdef DIVISE

__device__
__forceinline__
REAL fourthDer(REAL tfarLeft, REAL tLeft, REAL tCenter, REAL tRight, REAL tfarRight)
{
	return (tfarLeft - FOUR*tLeft + SIX*tCenter - FOUR*tRight + tfarRight)/(disc.dx4);
}

__device__
__forceinline__
REAL secondDer(REAL tLeft, REAL tRight, REAL tCenter)
{
	return (tLeft + tRight - TWO*tCenter)/(disc.dx2);
}

__device__
__forceinline__
REAL convect(REAL tLeft, REAL tRight)
{
	return (tRight*tRight - tLeft*tLeft)/(disc.dxTimes4);
}

#else

__device__
__forceinline__
REAL fourthDer(REAL tfarLeft, REAL tLeft, REAL tCenter, REAL tRight, REAL tfarRight)
{
	return (tfarLeft - FOUR*tLeft + SIX*tCenter - FOUR*tRight + tfarRight)*(disc.dx4);
}

__device__
__forceinline__
REAL secondDer(REAL tLeft, REAL tRight, REAL tCenter)
{
	return (tLeft + tRight - TWO*tCenter)*(disc.dx2);
}

__device__
__forceinline__
REAL convect(REAL tLeft, REAL tRight)
{
	return (tRight*tRight - tLeft*tLeft)*(disc.dxTimes4);
}

#endif

__device__
REAL stutterStep(const REAL *u, int loc[5])
{
	return u[loc[2]] - disc.dt_half * (convect(u[loc[1]], u[loc[3]]) + secondDer(u[loc[1]], u[loc[3]], u[loc[2]]) +
		fourthDer(u[loc[0]], u[loc[1]], u[loc[2]], u[loc[3]], u[loc[4]]));
}

__device__
REAL finalStep(const REAL *u, int loc[5])
{
	return (-disc.dt * (convect(u[loc[1]], u[loc[3]]) + secondDer(u[loc[1]], u[loc[3]], u[loc[2]]) +
		fourthDer(u[loc[0]], u[loc[1]], u[loc[2]], u[loc[3]], u[loc[4]])));
}

__global__
void
swapKernel(const REAL *passing_side, REAL *bin, int direction)
{
    int gid = blockDim.x * blockIdx.x + threadIdx.x; //Global Thread ID
    int lastidx = ((blockDim.x*gridDim.x)-1);
    int gidout = (gid + direction*blockDim.x) & lastidx;

    bin[gidout] = passing_side[gid];

}

//Classic
__global__
void
classicKS(const REAL *ks_in, REAL *ks_out, bool finally)
{
    int gid = blockDim.x * blockIdx.x + threadIdx.x; //Global Thread ID
    int lastidx = ((blockDim.x*gridDim.x)-1);
	int gidz[5];

	#pragma unroll
	for (int k=-2; k<3; k++) gidz[k+2] = (gid+k)&lastidx;

	if (finally) {
	ks_out[gid] += finalStep(ks_in, gidz);
	}
	else {
	ks_out[gid] = stutterStep(ks_in, gidz);
	}
}

__global__
void
upTriangle(const REAL *IC, REAL *outRight, REAL *outLeft)
{
	extern __shared__ REAL temper[];

	int gid = blockDim.x * blockIdx.x + threadIdx.x; //Global Thread ID
	int tididx = threadIdx.x + 2;

	int step2;

	int tid_top[5], tid_bottom[5];
	#pragma unroll
	for (int k = -2; k<3; k++)
	{
		tid_top[k+2] = tididx + k + disc.base;
		tid_bottom[k+2] = tididx + k;
	}

    //Assign the initial values to the first row in temper, each block
    //has it's own version of temper shared among its threads.
	temper[tididx] = IC[gid];

	__syncthreads();

	if (threadIdx.x > 1 && threadIdx.x <(blockDim.x-2))
	{
		temper[tid_top[2]] = stutterStep(temper, tid_bottom);
	}

	__syncthreads();

	for (int k = 4; k<(blockDim.x/2); k+=4)
	{
		if (threadIdx.x < (blockDim.x-k) && threadIdx.x >= k)
		{
			temper[tididx] += finalStep(temper, tid_top);
		}

		step2 = k + 2;
		__syncthreads();

		if (threadIdx.x < (blockDim.x-step2) && threadIdx.x >= step2)
		{
			temper[tid_top[2]] = stutterStep(temper, tid_bottom);
		}

		//Make sure the threads are synced
		__syncthreads();

	}

	writeOutRight(temper, outRight, outLeft, threadIdx.x, gid, blockDim.x);

}

__global__
void
downTriangle(REAL *IC, const REAL *inRight, const REAL *inLeft)
{
	extern __shared__ REAL temper[];

	int gid = blockDim.x * blockIdx.x + threadIdx.x;
	int tididx = threadIdx.x+2;

	int step2;

	int tid_top[5], tid_bottom[5];
	#pragma unroll
	for (int k = -2; k<3; k++)
	{
		tid_top[k+2] = tididx + k + disc.base;
		tid_bottom[k+2] = tididx + k;
	}

	readIn(temper, inRight, inLeft, threadIdx.x, gid);

	__syncthreads();

	for (int k = (disc.ht-2); k>0; k-=4)
	{
		if (tididx < (disc.base-k) && tididx >= k)
		{
			temper[tid_top[2]] = stutterStep(temper, tid_bottom);
		}

		step2 = k-2;
		__syncthreads();

		if (tididx < (disc.base-step2) && tididx >= step2)
		{
			temper[tididx] += finalStep(temper, tid_top);
		}

		//Make sure the threads are synced
		__syncthreads();
	}

    IC[gid] = temper[tididx];
}


__global__
void
wholeDiamond(REAL *inRight, REAL *inLeft, REAL *outRight, REAL *outLeft, const bool split)
{
	extern __shared__ REAL temper[];

	int gid = blockDim.x * blockIdx.x + threadIdx.x;
	int tididx = threadIdx.x + 2;

	int step2;

	int tid_top[5], tid_bottom[5];
	#pragma unroll
	for (int k = -2; k<3; k++)
	{
		tid_top[k+2] = tididx + k + disc.base;
		tid_bottom[k+2] = tididx + k;
	}

	readIn(temper, inRight, inLeft, threadIdx.x, gid);

	__syncthreads();

	for (int k = (disc.ht-2); k>0; k-=4)
	{
		if (tididx < (disc.base-k) && tididx >= k)
		{
			temper[tid_top[2]] = stutterStep(temper, tid_bottom);
		}

		step2 = k-2;
		__syncthreads();

		if (tididx < (disc.base-step2) && tididx >= step2)
		{
			temper[tididx] += finalStep(temper, tid_top);
		}

		//Make sure the threads are synced
		__syncthreads();
	}

    //-------------------TOP PART------------------------------------------

	if (threadIdx.x > 1 && threadIdx.x <(blockDim.x-2))
	{
		temper[tid_top[2]] = stutterStep(temper, tid_bottom);
	}

	__syncthreads();

	//The initial conditions are timslice 0 so start k at 1.
	for (int k = 4; k<(blockDim.x/2); k+=4)
	{
		if (threadIdx.x < (blockDim.x-k) && threadIdx.x >= k)
		{
			temper[tididx] += finalStep(temper, tid_top);
		}

		step2 = k+2;
		__syncthreads();

		if (threadIdx.x < (blockDim.x-step2) && threadIdx.x >= step2)
		{
			temper[tid_top[2]] = stutterStep(temper, tid_bottom);
		}

		//Make sure the threads are synced
		__syncthreads();

	}

	//After the triangle has been computed, the right and left shared arrays are
	//stored in global memory by the global thread ID since (conveniently),
	//they're the same size as a warp!
	if (split)
	{
		writeOutLeft(temper, outRight, outLeft, threadIdx.x, gid, blockDim.x);
	}
	else
	{
		writeOutRight(temper, outRight, outLeft, threadIdx.x, gid, blockDim.x);
	}


}

double
classicWrapper(const int bks, int tpb, const int dv, const double dt, const double t_end,
    REAL *IC, REAL *T_f, const double freq, ofstream &fwr)
{
    REAL *dks_in, *dks_out;

    cudaMalloc((void **)&dks_in, sizeof(REAL)*dv);
    cudaMalloc((void **)&dks_out, sizeof(REAL)*dv);

    // Copy the initial conditions to the device array.
    cudaMemcpy(dks_in,IC,sizeof(REAL)*dv,cudaMemcpyHostToDevice);

    double t_eq = 0.0;
    double twrite = freq;

    while (t_eq <= t_end)
    {
        classicKS <<< bks,tpb >>> (dks_in, dks_out, false);
        classicKS <<< bks,tpb >>> (dks_out, dks_in, true);
        t_eq += dt;

        if (t_eq > twrite)
        {
            cudaMemcpy(T_f, dks_in, sizeof(REAL)*dv, cudaMemcpyDeviceToHost);

			fwr << " Velocity " << t_eq << " ";
            for (int k = 0; k<dv; k++)
            {
                fwr << T_f[k] << " ";
            }
            fwr << endl;

            twrite += freq;
        }
    }

    cudaMemcpy(T_f, dks_in, sizeof(REAL)*dv, cudaMemcpyDeviceToHost);

    cudaFree(dks_in);
    cudaFree(dks_out);

    return t_eq;
}

//The host routine.
double
sweptWrapper(const int bks, int tpb, const int dv, const double dt, const double t_end,
	REAL *IC, REAL *T_f, const double freq, ofstream &fwr)
{

	REAL *d_IC, *d0_right, *d0_left, *d2_right, *d2_left;

	cudaMalloc((void **)&d_IC, sizeof(REAL)*dv);
	cudaMalloc((void **)&d0_right, sizeof(REAL)*dv);
	cudaMalloc((void **)&d0_left, sizeof(REAL)*dv);
	cudaMalloc((void **)&d2_right, sizeof(REAL)*dv);
	cudaMalloc((void **)&d2_left, sizeof(REAL)*dv);

	// Copy the initial conditions to the device array.
	cudaMemcpy(d_IC,IC,sizeof(REAL)*dv,cudaMemcpyHostToDevice);
	//Start the counter and start the clock.
	//
	//Every other step is a full timestep and each cycle is half tpb steps.
	const double t_fullstep = 0.25 * dt * (double)tpb;
	double twrite = freq;

	const size_t smem = (2*tpb+8)*sizeof(REAL);

	upTriangle <<< bks,tpb,smem >>> (d_IC, d0_right, d0_left);

	//Split
	wholeDiamond <<< bks,tpb,smem >>> (d0_right, d0_left, d2_right, d2_left, true);

	double t_eq = t_fullstep;

	// Call the kernels until you reach the iteration limit.
	while(t_eq < t_end)
	{

		wholeDiamond <<< bks,tpb,smem >>> (d2_right, d2_left, d0_right, d0_left, false);

		//So it always ends on a left pass since the down triangle is a right pass.

		//Split
		wholeDiamond <<< bks,tpb,smem >>> (d0_right, d0_left, d2_right, d2_left, true);

		t_eq += t_fullstep;

	 	if (t_eq > twrite)
		{
			downTriangle <<< bks,tpb,smem >>> (d_IC,d2_right,d2_left);

			cudaMemcpy(T_f, d_IC, sizeof(REAL)*dv, cudaMemcpyDeviceToHost);

			fwr << " Velocity " << t_eq << " ";

			for (int k = 0; k<dv; k++)	fwr << T_f[k] << " ";

			fwr << endl;

			upTriangle <<< bks,tpb,smem >>> (d_IC,d0_right,d0_left);

			//Split
			wholeDiamond <<< bks,tpb,smem >>> (d0_right,d0_left,d2_right,d2_left,true);

			t_eq += t_fullstep;

			twrite += freq;
		}

	}

	downTriangle <<< bks,tpb,smem >>>(d_IC,d2_right,d2_left);

	cudaMemcpy(T_f, d_IC, sizeof(REAL)*dv, cudaMemcpyDeviceToHost);

	cudaFree(d_IC);
	cudaFree(d0_right);
	cudaFree(d0_left);
	cudaFree(d2_right);
	cudaFree(d2_left);

	return t_eq;

}

int main( int argc, char *argv[])
{

	if (argc < 9)
	{
		cout << "The Program takes 9 inputs, #Divisions, #Threads/block, deltat, finish time, output frequency..." << endl;
        cout << "Classic/Swept, CPU sharing Y/N (Ignored), Variable Output File, Timing Output File (optional)" << endl;
		exit(-1);
	}

	cout.precision(10);
	// Choose the GPGPU.  This is device 0 in my machine which has 2 devices.
	cudaSetDevice(0);
	if (sizeof(REAL)>6) cudaDeviceSetSharedMemConfig(cudaSharedMemBankSizeEightByte);

	const int dv = atoi(argv[1]); //Number of spatial points
	const int tpb = atoi(argv[2]); //Threads per Block
    const double dt = atof(argv[3]); //delta T timestep
	const double tf = atof(argv[4]) - 0.5*dt; //Finish time
    const double freq = atof(argv[5]); //Output frequency
    const int scheme = atoi(argv[6]); //1 for Swept 0 for classic
    // const int tst = atoi(argv[7]); CPU/GPU share
    const int bks = dv/tpb; //The number of blocks
	const double lx = dv*dx;
	char const *prec;
	prec = (sizeof(REAL)<6) ? "Single": "Double";

	cout << "KS --- #Blocks: " << bks << " | Length: " << lx << " | Precision: " << prec << " | dt/dx: " << dt/dx << endl;

	//Conditions for main input.  Unit testing kinda.
	//dv and tpb must be powers of two.  dv must be larger than tpb and divisible by
	//tpb.

	if ((dv & (tpb-1) !=0) || (tpb&31) != 0)
    {
        cout << "INVALID NUMERIC INPUT!! "<< endl;
        cout << "2nd ARGUMENT MUST BE A POWER OF TWO >= 32 AND FIRST ARGUMENT MUST BE DIVISIBLE BY SECOND" << endl;
        exit(-1);
    }

	#ifdef DIVISE
	discConstants dsc = {
		(FOUR*dx), //dx
		(dx*dx), //dx^2
		(dx*dx*dx*dx), //dx^4
		dt, //dt
		dt*0.5, //dt half
		tpb + 4, //length of row of shared array
		(tpb+4)/2, //midpoint of shared array row
		dv-1 //last global thread id
	};

	#else
	discConstants dsc = {
		ONE/(FOUR*dx), //dx
		ONE/(dx*dx), //dx^2
		ONE/(dx*dx*dx*dx), //dx^4
		dt, //dt
		dt*0.5, //dt half
		tpb + 4, //length of row of shared array
		(tpb+4)/2, //midpoint of shared array row
		dv-1 //last global thread id
	};
	#endif
	// Initialize arrays.
    REAL *IC, *T_final;

	cudaHostAlloc((void **) &IC, dv*sizeof(REAL), cudaHostAllocDefault);
	cudaHostAlloc((void **) &T_final, dv*sizeof(REAL), cudaHostAllocDefault);

    // IC = (REAL *) malloc(dv*sizeof(REAL));
    // T_final = (REAL *) malloc(dv*sizeof(REAL));

	// Inital condition
	for (int k = 0; k<dv; k++)
	{
		IC[k] = initFun((REAL)k*(REAL)dx);
	}

	// Call out the file before the loop and write out the initial condition.
	ofstream fwr;
	fwr.open(argv[8],ios::trunc);
    fwr.precision(10);

	// Write out x length and then delta x and then delta t.
	// First item of each line is timestamp.
	fwr << lx << " " << dv << " " << dx << " " << endl << " Velocity " << 0 << " ";

	for (int k = 0; k<dv; k++) fwr << IC[k] << " ";

	fwr << endl;
	// Transfer data to GPU.

	// This puts the constant part of the equation in constant memory
	cudaMemcpyToSymbol(disc,&dsc,sizeof(dsc));

	// Start the counter and start the clock.
	cudaEvent_t start, stop;
	float timed;
	cudaEventCreate( &start );
	cudaEventCreate( &stop );
	cudaEventRecord( start, 0);

	// Call the kernels until you reach the iteration limit.
	double tfm;
	if (scheme)
    {
		cout << "Swept" << endl;
		tfm = sweptWrapper(bks, tpb, dv, dsc.dt, tf, IC, T_final, freq, fwr);
	}
	else
	{
		cout << "Classic" << endl;
		tfm = classicWrapper(bks, tpb, dv, dsc.dt, tf, IC, T_final, freq, fwr);
	}

	// Show the time and write out the final condition.
	cudaEventRecord(stop, 0);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime( &timed, start, stop);

	timed *= 1.e3;

	double n_timesteps = tfm/dt;

    double per_ts = timed/n_timesteps;

    cout << n_timesteps << " timesteps" << endl;
	cout << "Averaged " << per_ts << " microseconds (us) per timestep" << endl;

    if (argc>8)
    {
        ofstream ftime;
        ftime.open(argv[9],ios::app);
    	ftime << dv << "\t" << tpb << "\t" << per_ts << endl;
    	ftime.close();
    }

	fwr << " Velocity " << tfm << " ";
	for (int k = 0; k<dv; k++) fwr << T_final[k] << " ";

    fwr << endl;

	fwr.close();

	cudaDeviceSynchronize();
	// Free the memory and reset the device.

	cudaEventDestroy( start );
	cudaEventDestroy( stop );
	cudaDeviceReset();
	cudaFreeHost(IC);
    cudaFreeHost(T_final);


	return 0;

}
