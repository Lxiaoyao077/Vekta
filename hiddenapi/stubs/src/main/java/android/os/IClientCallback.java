package android.os;
public interface IClientCallback extends IInterface
{
    public static abstract class Stub extends android.os.Binder implements android.os.IClientCallback {
    }
    /**
     * Called when the number of clients of a registered service crosses zero in either
     * direction, as servicemanager sees it on its own interval.
     *
     * @param registered the binder the callback was registered with
     * @param hasClients whether anything other than servicemanager holds it
     */
    public void onClients(android.os.IBinder registered, boolean hasClients) throws android.os.RemoteException;
}
